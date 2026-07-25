module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::hbigint;
import duktape::dtoa_bindings;
import std::io;
import std::math;

// ============================================================================
// Class parsing (ES6)
// ============================================================================

/// Lazily initialise a hidden field-init context (__field_init__ /
/// __static_init__): a fresh CompilerContext sharing the lexer and heap,
/// wired to see the class's private-name scope, with initializers forbidden
/// from using `arguments` or `super()` (ES2022 §15.7.10). Public and private
/// field initializers share one context per class (per static-ness) so
/// initialization order matches source order.
fn void CompilerContext.ensure_field_init_ctx(&self, CompilerContext* target_ctx, bool is_static) {
    target_ctx.init(self.lexer, self.heap);
    target_ctx.lexer.set_strict(true);
    target_ctx.in_class_body = self.in_class_body;
    target_ctx.has_super_binding = self.has_super_binding;
    target_ctx.super_is_home_object = self.super_is_home_object;
    target_ctx.super_is_static_method = is_static;
    target_ctx.is_constructable = false;  // super() forbidden in initializers
    target_ctx.forbid_arguments = true;
    target_ctx.adopt_private_names(self);
    target_ctx.private_scope_start = self.private_scope_start;
    target_ctx.private_scope_depth = self.private_scope_depth;
    target_ctx.emit_simple(Opcode.PUSH_LEX);
}

/// Format a numeric literal's canonical property-key text (ES2015 §7.1.12.1
/// ToString applied to the NumericValue) into `buf`. Numeric literal tokens
/// are always finite. Used for field-name inference on numeric keys
/// (`class C { 0x10 = fn }` → fn.name "16").
fn char[] format_field_number_key(double val, char[] buf) {
    if (val == 0.0) {
        if (buf.len > 0) { buf[0] = '0'; return buf[:1]; }
        return buf[:0];
    }
    char[64] local;
    usz n = 0;
    if (val == math::trunc(val) && val > -1e21 && val < 1e21) {
        char[] printed = io::bprintf(&local, "%.0f", val) ?? local[..0];
        n = printed.len;
    } else {
        char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
        int len = dtoa_bindings::duktape_js_dtoa(&local, val, 10, 0,
            dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
        n = len > 0 ? (usz)len : 0;
    }
    if (n == 0 || n > buf.len) return buf[..0];
    for (usz i = 0; i < n; i++) buf[i] = local[i];
    return buf[..n];
}

/// Create a default constructor CompiledFunction without using the lexer.
/// has_super: if true, creates `constructor(...args) { super(...args); }`
/// otherwise creates `constructor() {}`.
/// class_name: when non-empty, used as the constructor's name property
/// (per ES2015 §14.5.14 step 17 + SetFunctionName, a class declaration's
/// default constructor inherits the class name as its .name).
fn CompiledFunction*? make_default_constructor(Heap* hp, bool has_super, char[] class_name) {
    void* raw = hp.alloc_func(hp.heap_udata, CompiledFunction::size);
    if (raw == null) return COMPILE_ERROR~;
    mem::clear(raw, (sz)(CompiledFunction::size));

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;
    func.flags.is_constructable = true;
    // Class constructor: .prototype is non-configurable per ES2015 §14.5.14
    // step 25.  CLOSURE checks this flag and uses PROP_FLAGS_WENC (configurable=false).
    func.flags.is_class_ctor = true;

    // Set the constructor's name from the class name (per ES2015 SetFunctionName).
    // Heap-allocate so the name lives as long as the function (was session 219's
    // B09 fix for compile_inner_function; apply same here).
    if (class_name.len > 0) {
        // `mem`, matching every other name_ptr/src_ptr site: free_compiled_funcs
        // releases these with mem::free and cannot tell the allocators apart.
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)class_name.len + 1)) ?? null;
        if (name_heap == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        for (usz i = 0; i < class_name.len; i++) name_heap[i] = class_name[i];
        name_heap[class_name.len] = 0;
        func.name_ptr = name_heap;
        func.name_len = (uint)class_name.len;
    }

    if (has_super) {
        // constructor(...args) { super(...args); }
        func.flags.has_rest = true;
        func.num_args = 0;
        func.num_formals = 0;   // rest param doesn't count toward length
        func.num_regs = 24;     // r0=rest, r1=__super__, r2=this, r3..r22=spread, r23=count

        // Create interned string constant for "__super__"
        HString* super_str = hp.str_intern("__super__");
        if (super_str == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        func.const_count = 1;
        usz const_bytes = (usz)func.const_count * TVal::size;
        func.constants = (TVal*)hp.alloc_func(hp.heap_udata, const_bytes);
        if (func.constants == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        TVal super_tv;
        super_tv.set_string(super_str);
        func.constants[0] = super_tv;

        // Build bytecode:
        //   PUSH_LEX                      ; allocate lexical env
        //   GETVAR  r1, __super__          ; load superclass
        //   LDTHIS  r2                     ; load this
        //   FWD_ARGS r3, r23, r0           ; forward rest args directly (no @@iterator), count→r23
        //   SUPER_CALL_S r2, r1, r23       ; super(r1=superclass), result→r2
        //   POP_LEX
        //   RET r2
        func.code_count = 7;
        usz code_bytes = (usz)func.code_count * Instruction::size;
        func.code = (Instruction*)hp.alloc_func(hp.heap_udata, code_bytes);
        if (func.code == null) {
            hp.free_func(hp.heap_udata, func.constants);
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }

        Instruction* c = func.code;
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);
        c[1] = bytecode::make_a_bc(Opcode.GETVAR, 1, 0);   // r1, constant idx 0
        c[2] = bytecode::make_abc(Opcode.LDUNDEF, 2, 0, 0);  // r2 = placeholder (this-slot for SUPER_CALL)
        c[3] = bytecode::make_abc(Opcode.FWD_ARGS, 3, 23, 0);  // r3.. = fwd dest, r23 = count (no @@iterator)
        c[4] = bytecode::make_abc(Opcode.SUPER_CALL_S, 2, 1, 23); // result=r2, callee=r1, nargs_reg=r23
        c[5] = bytecode::make_abc(Opcode.POP_LEX, 0, 0, 0);
        c[6] = bytecode::make_abc(Opcode.RET, 2, 0, 0);
    } else {
        // constructor() {}
        func.num_args = 0;
        func.num_formals = 0;
        func.num_regs = 1;

        usz code_bytes = 3 * Instruction::size;
        void* code_raw = hp.alloc_func(hp.heap_udata, code_bytes);
        if (code_raw == null) { hp.free_func(hp.heap_udata, raw); return COMPILE_ERROR~; }
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
fn void? CompilerContext.class_declaration(&self, char[]* out_name = null, bool allow_anonymous = false) {
    // Capture class source start before consuming `class` keyword.
    self.lexer.refresh_token_start();
    uint class_decl_src_start = self.lexer.token_start;
    self.expect(TokenType.CLASS)!;
    // Per ES2024 §15.7.1, BindingIdentifier may be `await` (in non-module)
    // or `yield` (in non-generator). Accept these contextual keywords.
    // When allow_anonymous is set (`export default class ... {}`), a missing
    // name is legal — the class binds to `*default*` (§16.2.3.7).
    // Intern the name immediately: an escaped class name (`class \u{43} {}`)
    // borrows the lexer's shared ident_buf scratch, which the extends clause
    // and class body parsed below will overwrite. declare_var stores this
    // slice into scope_stack, which outlives the current token.
    char[] class_name;
    TokenType name_tt = self.peek_type();
    if (name_tt == TokenType.IDENTIFIER) {
        class_name = self.advance()!.str_value;
        class_name = ((Heap*)self.heap).str_intern(class_name).get_data();
    } else if ((name_tt == TokenType.AWAIT && !self.is_module && !self.forbid_await) ||
               (name_tt == TokenType.YIELD && !self.is_generator)) {
        class_name = self.advance()!.str_value;
        class_name = ((Heap*)self.heap).str_intern(class_name).get_data();
    } else if (allow_anonymous && (name_tt == TokenType.EXTENDS || name_tt == TokenType.LBRACE)) {
        // ES2024 §16.2.3.7: `export default class { ... }` — the class's
        // [[FunctionName]] is the literal string "default" (visible via
        // `this.name` in static field initializers — see
        // test262 class-name-static-initializer-default-export). The
        // OUTER binding uses an internal name ("*default*") so the
        // declared-export machinery can identify the symbol; the function
        // object's `.name` is separately overridden to "default" in
        // parse_class_tail_with_name via the is_default_export flag.
        class_name = "*default*";
    } else {
        return COMPILE_ERROR~;
    }
    // Surface the bound class name to callers (e.g. `export class Foo {}`,
    // which must register `Foo` as an export without re-parsing the header).
    if (out_name != null) *out_name = class_name;

    // ES6 §14.5.14 Runtime Semantics: ClassDefinitionEvaluation creates a
    // fresh lexical environment (classScope) as a child of the current
    // LexicalEnvironment, with an *immutable* CreateImmutableBinding for the
    // class name.  Methods and the constructor close over classScope, so the
    // class name resolves to the constructor inside the class body but is
    // shadowed by the outer scope from outside.
    //
    // We model this with PUSH_LEX (allocate classScope) and PUTLEX_C
    // (mark the binding non-writable, which is what immutable binding maps
    // to in our env: PUTVAR on a non-writable binding throws TypeError).
    // Then we POP_LEX after storing the constructor into the OUTER let
    // binding (so `Foo` resolves to the constructor from the outer scope).

    // Outer let-style binding: holds the constructor after the class evaluates.
    // Same as the existing let/const treatment for class declarations.
    ushort class_reg = self.declare_var(class_name, LET);
    uint class_name_idx = self.add_string_constant(class_name);

    // Push the classScope (child of current lex_env).
    self.emit_simple(Opcode.PUSH_LEX);

    // Create the immutable className binding as TDZ (temporal dead zone).
    // INITTZ marks the binding as uninitialized so that any access before
    // the constructor is stored (below) throws ReferenceError.  This is
    // required by ES2015 §14.5.14 step 3: the extends clause is evaluated
    // while the class name binding is still uninitialized, so
    // `class x extends x {}` correctly throws ReferenceError.
    self.emit_a_bc(Opcode.INITTZ, 0, class_name_idx);

    // Parse extends clause and class body.  Methods CLOSURE here, capturing
    // classScope as their lex_env so the class name resolves to the
    // constructor from inside method bodies. parse_class_tail_with_name
    // emits the PUTLEX_C (initializing the class-name binding) and the
    // matching POP_LEX BEFORE the static initializer runs — required so
    // static field initializers can see the class name (§15.7.14).
    // Anonymous default-export: `export default class { ... }` — the
    // constructor's visible `.name` must be the literal "default"
    // (ES2024 §16.2.3.7), distinct from the internal binding name
    // "*default*" used by the declared-export machinery. A named
    // `export default class Foo {}` keeps `.name = "Foo"`.
    bool is_default_export = allow_anonymous && str_eq(class_name, "*default*");
    ushort ctor_reg = self.parse_class_tail_with_name(class_name, class_decl_src_start, false, class_reg, class_name_idx, is_default_export)!;

    // Store the constructor into the OUTER let binding so `Foo` resolves to
    // the constructor from outside the class declaration as well.
    self.emit_a_bc(Opcode.PUTLEX, (uint)class_reg, class_name_idx);
    self.free_reg(ctor_reg);
}

/// Parse a class expression: `class [Name] [extends Base] { body }`
/// Returns the register holding the constructor.
fn ushort? CompilerContext.class_expression(&self) {
    // Capture class source start before consuming `class` keyword.
    self.lexer.refresh_token_start();
    uint class_expr_src_start = self.lexer.token_start;
    self.expect(TokenType.CLASS)!;

    // Optional class name (only visible inside the class body).
    char[] name;
    uint class_name_idx = 0;
    ushort name_reg = MAX_REGISTERS;
    bool has_name = false;
    TokenType class_name_tt = self.peek_type();
    bool is_valid_class_name = (class_name_tt == TokenType.IDENTIFIER) ||
        (class_name_tt == TokenType.AWAIT && !self.is_module && !self.forbid_await) ||
        (class_name_tt == TokenType.YIELD && !self.is_generator);
    if (is_valid_class_name) {
        Token name_tok = self.advance()!;
        // Intern now: an escaped class name borrows the lexer's shared
        // ident_buf scratch, which the extends clause and class body parsed
        // below will overwrite. declare_var stores this slice into
        // scope_stack, which outlives the current token.
        name = ((Heap*)self.heap).str_intern(name_tok.str_value).get_data();
        // For named class expressions, track the name on the scope stack so
        // inner function expressions can resolve it (name inference).
        name_reg = self.declare_var(name, LET);
        class_name_idx = self.add_string_constant(name);
        has_name = true;
        // Explicit name overrides any inferred name (clear the flag so a
        // following anonymous class does not inherit it stale).
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    } else if (self.has_inferred_name) {
        // ES2015 §14.5.14 SetFunctionName / NamedEvaluation: an anonymous
        // class expression picks up the inferred name from an enclosing
        // `var f = class {}` or `{ p: class {} }` assignment context.
        // The name is display-only — it does NOT create a scope binding —
        // so we set `name` but leave `has_name` false.
        name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // Push classScope only when we have a class name — the immutable binding
    // is the only thing the spec puts in classScope, and anonymous class
    // expressions don't need one.  When we DO push, the classScope is a child
    // of the current lex env; methods CLOSURE'd inside capture it.
    if (has_name) {
        self.emit_simple(Opcode.PUSH_LEX);

        // Create the immutable className binding as TDZ (temporal dead zone).
        // INITTZ marks the binding as uninitialized so that any access before
        // the constructor is stored (below) throws ReferenceError.
        self.emit_a_bc(Opcode.INITTZ, 0, class_name_idx);
    }

    // Parse extends clause and class body.
    // Anonymous class expression: pass empty name so default constructor
    // has empty .name (per ES2015 anonymous class expression). The
    // className binding (when set up above) is initialized by
    // parse_class_tail_with_name itself, BEFORE its static initializer,
    // so its POP_LEX also happens inside the call and outer binding
    // initialization must NOT be repeated here.  Pass name_reg/idx for the
    // named case (so PUTLEX_C + POP_LEX are emitted internally) and
    // MAX_REGISTERS/0 for the anonymous case (so neither runs).
    ushort ctor_reg = self.parse_class_tail_with_name(
        name, class_expr_src_start, true,
        has_name ? name_reg : MAX_REGISTERS,
        has_name ? class_name_idx : 0
    )!;

    return ctor_reg;
}

/// Parse the tail of a class: optional `extends` clause + class body.
/// Returns the register holding the constructor function.
/// `class_name`: when non-empty, the default constructor inherits this name
/// as its `.name` property (ES2015 §14.5.14 + SetFunctionName).
/// `class_name_reg`/`class_name_str_idx`: when supplied (non-zero), the
/// compiler-emitted classScope binding for the class name is initialized with
/// the constructor AND the matching POP_LEX is emitted BEFORE the static
/// initializer runs.  This satisfies ES2022 §15.7.14 ClassDefinitionEvaluation:
/// the class name binding must be live by the time static field initializers
/// run (so e.g. `(Object.preventExtensions(C), "Test262")` inside a static
/// initializer can refer to `C`).  When zero, the caller is responsible for
/// the PUTLEX_C/POP_LEX — pass through to the previous single-mode behaviour.
///
/// `is_default_export`: when true, the class is the anonymous body of
/// `export default class { ... }`. The runtime-visible `.name` must be the
/// literal string "default" (ES2024 §16.2.3.7), distinct from the binding
/// name "*default*" the compiler uses for the declared-export machinery.
fn ushort? CompilerContext.parse_class_tail_with_name(&self, char[] class_name, uint class_src_start = 0xFFFFFFFF, bool is_expr = false, ushort class_name_reg = MAX_REGISTERS, uint class_name_str_idx = 0, bool is_default_export = false) {
    // Save state for restoration after class body
    bool saved_in_class_body = self.in_class_body;
    bool saved_has_super = self.has_super_binding;
    bool saved_super_is_home = self.super_is_home_object;
    self.in_class_body = true;
    self.has_super_binding = false;

    // Always declare __super__ so that any method body can resolve it via GETVAR.
    // For `extends Base`, __super__ = Base (super_is_home_object=false, so
    // GetSuperBase = __super__.prototype = Base.prototype).
    // For classes without extends, __super__ = C.prototype (super_is_home_object=true,
    // so GetSuperBase = Object.getPrototypeOf(__super__) = Object.prototype).
    char[] super_name = "__super__";
    ushort super_reg = self.declare_var(super_name, LET);
    uint super_name_idx = self.add_string_constant(super_name);

    // __static_super__ = the class constructor itself. Static method bodies
    // resolve `super.x` against this binding via GETPROTO (HomeObject = the
    // constructor, per §13.3.7.1), independent of the extends clause: it is
    // bound to ctor_reg once the constructor closure exists, below.
    char[] static_super_name = "__static_super__";
    ushort static_super_reg = self.declare_var(static_super_name, LET);
    uint static_super_name_idx = self.add_string_constant(static_super_name);

    // For default-exported anonymous classes, the constructor's visible
    // `.name` is the literal "default" (ES2024 §16.2.3.7); the binding
    // name "*default*" is a compiler-private symbol.
    char[] ctor_runtime_name = is_default_export ? "default" : class_name;

    // Parse optional extends clause
    ushort base_reg = MAX_REGISTERS;
    if (self.match(TokenType.EXTENDS)) {
        base_reg = self.assignment_expr()!;
        // ES2022 §15.7.14 step 5.f: if superclass is not null and not a
        // constructor, throw TypeError BEFORE accessing .prototype.
        self.emit_abc(Opcode.CHKCTOR, (uint)base_reg, 0, 0);
        self.has_super_binding = true;
        // __super__ = Base; GetSuperBase = __super__.prototype = Base.prototype
        self.super_is_home_object = false;
        self.emit_abc(Opcode.LDREG, (uint)super_reg, (uint)base_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)super_reg, super_name_idx);
    } else {
        // No extends: __super__ will be set to C.prototype after proto_reg is created.
        // GetSuperBase = GETPROTO(__super__) = Object.prototype.
        self.super_is_home_object = true;
        // has_super_binding remains false (super() calls are not allowed),
        // but in_class_body = true allows super.x / super[x] syntax.
    }

    // Private class members (ES2022): push a fresh private-name scope and
    // pre-declare every `#name` in the class body (Phase A, plan 054 §2a)
    // BEFORE any member body compiles, so a field initializer may reference
    // a `#name` declared later in the same class. The lexer is currently
    // positioned right before the body's `{`, which prescan_private_names
    // expects; it fully restores lexer state on return.
    self.push_private_scope();
    self.prescan_private_names()!;

    // The class's brand(s): stamped on every instance (base ctor / super() —
    // see vm_calls.c3 / vm_execute.c3) whenever the class declares any
    // INSTANCE private member, and on the constructor object itself (emitted
    // directly in this class's own bytecode, below) whenever it declares any
    // STATIC private member (P5) — a distinct symbol, so `C.#m` never
    // succeeds on an instance and `instance.#staticThing` never succeeds on
    // the class (test: p5-static-brand-separate-from-instance). Declared
    // right after the pre-scan (which already classified is_static per
    // entry) so every PrivateNameEntry can be backfilled with the RIGHT
    // brand binding name before any member body — which may reference an
    // entry — compiles.
    bool has_brand = false;
    char[] brand_slot_name = "";
    bool has_static_brand = false;
    char[] static_brand_slot_name = "";
    {
        uint priv_scope_begin0 = self.private_scope_depth > 0
            ? self.private_scope_start[self.private_scope_depth - 1] : 0;
        for (uint pbi = priv_scope_begin0; pbi < self.private_name_table.count; pbi++) {
            if (self.private_name_table.entries[pbi].is_static) {
                if (!has_static_brand) {
                    has_static_brand = true;
                    static_brand_slot_name = self.declare_class_static_brand();
                }
                self.private_name_table.entries[pbi].brand_slot_name = static_brand_slot_name;
            } else {
                if (!has_brand) {
                    has_brand = true;
                    brand_slot_name = self.declare_class_brand();
                }
                self.private_name_table.entries[pbi].brand_slot_name = brand_slot_name;
            }
        }
    }

    // Parse class body
    self.expect(TokenType.LBRACE)!;

    // Track methods found in the class body
    ClassMethod[MAX_CLASS_METHODS] methods;
    ushort method_count = 0;
    // Per-class-body counter for computed public-field-key hidden slots
    // (P7) — combined with the class id to build unique binding names.
    uint computed_field_key_count = 0;

    // Instance field initializers compile into one hidden __field_init__
    // function, in source order (plan 054 §2d). Created lazily on the first
    // `#name = expr;` / `#name;` field so classes without fields pay no cost.
    CompilerContext field_init_ctx;
    bool has_field_init = false;
    uint field_count = 0;

    // Static private field initializers (P5) compile into a second hidden
    // function, __static_init__, run once right after class evaluation with
    // `this` = the constructor (spec: static field initializers run at
    // ClassDefinitionEvaluation time, not per-instance).
    CompilerContext static_init_ctx;
    bool has_static_init = false;
    uint static_field_count = 0;

    // Track constructor
    uint ctor_inner_idx = 0xFFFFFFFF;  // sentinel

    // ES2015 §14.1.20 step 6.d: if the class has a static `name` method, the
    // constructor's auto-set name will be overridden by the static method
    // installation. Track it as we parse so the constructor's name is
    // suppressed when a static name is present.
    bool class_has_static_name = false;

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        // Skip semicolons (empty class elements)
        if (self.match(TokenType.SEMICOLON)) {
            continue;
        }

        // Refresh `lexer.token_start` so the offset captured below reflects
        // this iteration's first token (not stale state from the previous
        // element's closing `}`).
        self.lexer.refresh_token_start();

        // Class static initialization block (ES2022 §15.7.11): `static { ... }`.
        // Checked before match_static_modifier — `{` can never start a
        // PropertyName, so this is never ambiguous with `static` used as a
        // field/method name. Compiled as its own zero-arg function (own var/
        // lex scope, unlike static field initializers which all share
        // __static_init__), then CLOSURE+CALL'd right here so it interleaves
        // with static field installs in source order (static-init-sequence).
        if (self.match_static_block_prefix()) {
            if (!has_static_init) {
                has_static_init = true;
                self.ensure_field_init_ctx(&static_init_ctx, true);
            }
            CompiledFunction* block_func = self.compile_static_block()!;
            uint block_idx = static_init_ctx.add_inner_func(block_func);
            ushort block_reg = static_init_ctx.alloc_reg();
            static_init_ctx.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)block_reg, block_idx));
            ushort block_this_slot = static_init_ctx.alloc_reg();  // must be block_reg + 1
            static_init_ctx.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)block_this_slot, 0));
            static_init_ctx.emit_abc(Opcode.CALL, (uint)block_reg, (uint)block_reg, 0);
            static_init_ctx.free_reg(block_this_slot);
            static_init_ctx.free_reg(block_reg);
            continue;
        }

        // Check for static modifier — only consume `static` when followed by
        // a method name (identifier, keyword, string, number, `[`, `*`, get/set).
        // When followed by `(`, `static` IS the method name, not a modifier.
        bool is_static = false;
        if (self.match_static_modifier()) {
            is_static = true;
            // Refresh so the source-start captured below is after `static`.
            self.lexer.refresh_token_start();
        }

        // Capture source start for Function.prototype.toString (ES2019 §19.2.3.5).
        // Per spec, the class method's source text does NOT include the `static`
        // keyword — it starts at the method-kind prefix (`get`/`set`/`*`/`async`)
        // or directly at the property name.  After a static modifier the lexer's
        // token_start may already point past a pushed-back `get`/`set` token, so
        // prefer the element start recorded by match_static_modifier.
        uint class_elem_src_start = self.lexer.token_start;
        if (is_static && self.static_elem_src_start != 0xFFFFFFFF) {
            class_elem_src_start = self.static_elem_src_start;
        }

        // Private instance/static field: `#name = expr;` or `#name;` — but
        // NOT when followed by `(`, which is a private method (P3, handled
        // below alongside public methods so generator/async modifiers and
        // compile_inner_function are shared).
        if (self.check(TokenType.HASH_IDENT) && !self.peek2_is_lparen()) {
            Token priv_tok = self.advance()!;
            char[] priv_name = priv_tok.str_value;
            PrivateNameEntry* entry = self.resolve_private_name(priv_name)!;
            // Capture the slot name NOW, before compiling the initializer.
            // `entry` points into the shared private-name table's `entries`
            // buffer; a nested class inside `assignment_expr()` below can
            // declare private names and grow (realloc) that buffer, dangling
            // `entry`. The slot_name slice itself is interned (stable), so
            // copying the slice is enough — we never touch `entry` again after
            // the initializer compiles.
            char[] entry_slot_name = entry.slot_name;

            CompilerContext* target_ctx = is_static ? &static_init_ctx : &field_init_ctx;
            bool* target_has_init = is_static ? &has_static_init : &has_field_init;
            if (!*target_has_init) {
                *target_has_init = true;
                self.ensure_field_init_ctx(target_ctx, is_static);
            }

            ushort init_reg;
            if (self.match(TokenType.ASSIGN)) {
                // ES2022 §15.7.10 step 7 / DefineField step 7: an anonymous
                // function definition initializer gets SetFunctionName with
                // the private name — "#field" (hash included).
                target_ctx.has_inferred_name = true;
                if (priv_name.len + 1 < 128) {
                    target_ctx.inferred_name_buf[0] = '#';
                    for (usz i = 0; i < priv_name.len; i++) {
                        target_ctx.inferred_name_buf[i + 1] = priv_name[i];
                    }
                    target_ctx.inferred_name_len = (ushort)(priv_name.len + 1);
                } else {
                    target_ctx.inferred_name_len = 0;
                }
                init_reg = target_ctx.assignment_expr()!;
                target_ctx.has_inferred_name = false;
                target_ctx.inferred_name_len = 0;
            } else {
                init_reg = target_ctx.alloc_reg();
                target_ctx.emit_abc(Opcode.LDUNDEF, (uint)init_reg, 0, 0);
            }

            // Field terminator: explicit `;`, the class body's `}`, or ASI at
            // a line terminator (ES2024 §12.10.1). A same-line token with no
            // separator (`#x = 1 y`) is a SyntaxError.
            target_ctx.expect_semicolon_or_asi()!;

            // this[#name_sym] = init_reg — PrivateFieldAdd bypasses setters,
            // proxies, and the extensibility check (INITPROP_PRIV). For a
            // static field, `this` inside __static_init__ is bound to the
            // constructor (see __static_init__'s CALL emission below).
            ushort this_reg = target_ctx.alloc_reg();
            target_ctx.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_reg, 0));
            ushort key_reg = target_ctx.alloc_reg();
            target_ctx.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg,
                target_ctx.add_string_constant(entry_slot_name)));
            target_ctx.emit_abc(Opcode.INITPROP_PRIV, (uint)this_reg, (uint)key_reg, (uint)init_reg);
            target_ctx.free_reg(key_reg);
            target_ctx.free_reg(this_reg);
            target_ctx.free_reg(init_reg);

            if (is_static) { static_field_count++; } else { field_count++; }
            continue;
        }

        // ES2015 §14.4: generator-method shorthand — `*m() { yield ... }`.
        // Save the generator + async flags; they are only overridden right
        // before compiling the method body below. Anything parsed before that
        // (identifier method names, `[expr]` computed keys) runs in the
        // *enclosing* function's context, so we must not clear the flags here.
        bool saved_is_generator = self.is_generator;
        bool saved_is_user_generator = self.is_user_generator;
        bool saved_is_async = self.is_async;
        // ES2017 §14.6: async-method shorthand — `async m() { await ... }`.
        // `async` is not a keyword; match_async_method_prefix consumes it only
        // when it is a modifier (followed on the same line by a method name),
        // so `async() {}` still parses as a method named "async".
        bool is_async_method = self.match_async_method_prefix();
        bool is_generator_method = self.match(TokenType.STAR);

        // Get the method name
        Token method_name;
        bool is_constructor = false;
        bool is_getter = false;
        bool is_setter = false;
        // Private method/accessor (P3/P4): `#m()`, `get #x()`, `set #x(v)`.
        // The key is loaded from the private name's own symbol slot instead
        // of a string/computed-key constant — see the install loop below.
        bool is_private_member = false;
        char[] priv_member_name = {};

        // Track when method_name comes from a NUMBER token so the key constant
        // uses the numeric value (converted to string at runtime) instead of the
        // raw token text (e.g. "0x10" instead of "16").
        bool method_name_is_number = false;
        double method_name_num_value = 0.0;
        // Same idea for a BIGINT token (e.g. `1n() {}`) — key is
        // ToString(NumericValue(NumericLiteral)) per ES2020 PropertyName.
        bool method_name_is_bigint = false;
        char[] method_name_bigint_src = {};

        // Check for computed key [expr]
        bool has_computed_key = false;
        // True when the name came from a computed string-literal key
        // (`['constructor']`) collapsed to a fixed name — PropName of a
        // ComputedPropertyName is the empty string, so the field-name early
        // errors (constructor/prototype) must NOT fire for it (ES2022
        // §15.7.1); the runtime CreateDataPropertyOrThrow still applies.
        bool name_from_computed_string = false;
        uint computed_key_inner_idx = 0xFFFFFFFF;
        // When the enclosing context is a generator/async, compile the key
        // expression inline in the enclosing function so yield/await interact
        // with the enclosing generator/async.  Store the result register here.
        ushort computed_key_reg = 0xFFFF;

        if (self.check(TokenType.LBRACKET)) {
            self.advance()!;  // consume `[`
            // ES2015 §14.5.13 step 1: a computed key whose *literal string value* is
            // "prototype" combined with `static` is an early SyntaxError (covered by
            // §14.5.1's "static method named prototype" rule — test262
            // static-method-non-configurable-err).  Detect that literal-string form
            // at compile time so we can reject it cleanly instead of waiting for a
            // runtime TypeError out of DefinePropertyOrThrow.
            if (self.check(TokenType.STRING)) {
                // The STRING shortcut only applies when the next token is `]`
                // — i.e. `["foo"]` is genuinely a fixed-name key. Anything
                // else (`["foo" + "bar"]`, `["foo", "bar"]`) is a real
                // computed-key expression, not a literal collapsed to a
                // fixed name. Without this guard `["s" + "tatic"]` would
                // silently treat `"s"` as the literal name and the `+` as a
                // follow-up syntax error.
                Token? look_after_str = self.lexer.peek();
                bool is_collapsed_literal = false;
                if (try nxt = look_after_str) {
                    is_collapsed_literal = nxt.type == TokenType.RBRACKET;
                }
                if (is_collapsed_literal) {
                    Token str_tok = self.advance()!;
                    self.expect(TokenType.RBRACKET)!;
                    has_computed_key = false;
                    name_from_computed_string = true;
                    // Reuse the IDENTIFIER / string / static-prototype early-error check
                    // below by treating the string as a fixed-name method token.
                    method_name = str_tok;
                    // Fall through to the static-prototype check below.
                } else {
                    // Generic computed key (variable, expression, etc.).
                    has_computed_key = true;
                    if (self.is_generator || self.is_async) {
                        computed_key_reg = self.assignment_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                        computed_key_inner_idx = 0xFFFFFFFE;  // sentinel: inline
                    } else {
                        CompiledFunction* key_func = self.compile_key_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                        computed_key_inner_idx = self.add_inner_func(key_func);
                    }
                    method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
                }
            } else {
                // Generic computed key (variable, expression, etc.).
                has_computed_key = true;
                // When the enclosing context is a generator or async function,
                // the key expression may contain yield/await which must interact
                // with the enclosing generator/async.  Compile inline in the
                // enclosing function and store the result register.
                if (self.is_generator || self.is_async) {
                    computed_key_reg = self.assignment_expr()!;
                    self.expect(TokenType.RBRACKET)!;
                    computed_key_inner_idx = 0xFFFFFFFE;  // sentinel: inline
                } else {
                    CompiledFunction* key_func = self.compile_key_expr()!;
                    self.expect(TokenType.RBRACKET)!;
                    computed_key_inner_idx = self.add_inner_func(key_func);
                }
                method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
            }
        } else if (self.check(TokenType.HASH_IDENT)) {
            // Private method: `#m() {}` (accessors — `get #x`/`set #x` — are
            // detected below via the `get`/`set` IDENTIFIER branch, which
            // also accepts a following HASH_IDENT as the accessor's name).
            Token priv_name_tok = self.advance()!;
            is_private_member = true;
            priv_member_name = priv_name_tok.str_value;
            method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
        } else if (self.check(TokenType.IDENTIFIER)
               || lexer::keyword_to_string(self.peek_type()).len > 0) {
            // IDENTIFIER or any keyword (extends, class, if, return, etc.) as method name
            method_name = self.advance()!;
            // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
            // Skip when this is a generator-method shorthand — `*get` / `*set` is a SyntaxError.
            if (!is_generator_method && (method_name.str_value.len == 3
                 && method_name.str_value[0] == 'g'
                 && method_name.str_value[1] == 'e'
                 && method_name.str_value[2] == 't')
                || (!is_generator_method && method_name.str_value.len == 3
                    && method_name.str_value[0] == 's'
                    && method_name.str_value[1] == 'e'
                    && method_name.str_value[2] == 't')) {
                // Accessor only when the NEXT token can start a property
                // name; otherwise `get`/`set` is itself the member name —
                // `get() {}` (method), `get = 5` / `get;` / `get}` (P7
                // fields), `get: 1` (not a class element; errors later).
                bool next_starts_key = self.check(TokenType.IDENTIFIER)
                    || self.check(TokenType.STRING)
                    || self.check(TokenType.NUMBER)
                    || self.check(TokenType.BIGINT)
                    || self.check(TokenType.LBRACKET)
                    || self.check(TokenType.HASH_IDENT)
                    || lexer::keyword_to_string(self.peek_type()).len > 0;
                if (next_starts_key) {
                    // This is a getter/setter declaration
                    is_getter = (method_name.str_value[0] == 'g');
                    is_setter = !is_getter;
                    // Parse the actual property name
                    if (self.check(TokenType.LBRACKET)) {
                        // Computed getter/setter key
                        self.advance()!; // consume `[`
                        has_computed_key = true;
                        if (self.is_generator || self.is_async) {
                            computed_key_reg = self.assignment_expr()!;
                            self.expect(TokenType.RBRACKET)!;
                            computed_key_inner_idx = 0xFFFFFFFE;  // sentinel: inline
                        } else {
                            CompiledFunction* accessor_key_func = self.compile_key_expr()!;
                            self.expect(TokenType.RBRACKET)!;
                            computed_key_inner_idx = self.add_inner_func(accessor_key_func);
                        }
                        method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
                    } else if (self.check(TokenType.HASH_IDENT)) {
                        // `get #x() {}` / `set #x(v) {}`
                        Token acc_priv_tok = self.advance()!;
                        is_private_member = true;
                        priv_member_name = acc_priv_tok.str_value;
                        method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
                    } else if (self.check(TokenType.IDENTIFIER) || self.check(TokenType.STRING)
                               || lexer::keyword_to_string(self.peek_type()).len > 0) {
                        method_name = self.advance()!;
                    } else if (self.check(TokenType.NUMBER)) {
                        method_name = self.advance()!;
                        method_name_is_number = true;
                        method_name_num_value = method_name.num_value;
                    } else if (self.check(TokenType.BIGINT)) {
                        method_name = self.advance()!;
                        method_name_is_bigint = true;
                        method_name_bigint_src = method_name.str_value;
                    } else {
                        return COMPILE_ERROR~;
                    }
                    // Early error: getter/setter named "constructor" (non-static only)
                    if (!is_private_member && !is_static && method_name.str_value.len == 11
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
                        return COMPILE_ERROR~;
                    }
                }
            }
            // Check for constructor name and related early errors
            if (method_name.str_value.len == 11
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
                if (!is_static && (is_getter || is_setter)) {
                    // getter/setter named "constructor" — already handled above
                    return COMPILE_ERROR~;
                }
                if (ctor_inner_idx != 0xFFFFFFFF) {
                    // duplicate constructor is a SyntaxError
                    return COMPILE_ERROR~;
                }
                if (!is_static) {
                    is_constructor = true;
                }
            }
            // Early error: static method/getter/setter named "prototype"
            if (is_static && method_name.str_value.len == 9
                && method_name.str_value[0] == 'p'
                && method_name.str_value[1] == 'r'
                && method_name.str_value[2] == 'o'
                && method_name.str_value[3] == 't'
                && method_name.str_value[4] == 'o'
                && method_name.str_value[5] == 't'
                && method_name.str_value[6] == 'y'
                && method_name.str_value[7] == 'p'
                && method_name.str_value[8] == 'e') {
                return COMPILE_ERROR~;
            }
        } else if (self.check(TokenType.STRING)) {
            method_name = self.advance()!;
        } else if (self.check(TokenType.NUMBER)) {
            method_name = self.advance()!;
            method_name_is_number = true;
            method_name_num_value = method_name.num_value;
        } else if (self.check(TokenType.BIGINT)) {
            method_name = self.advance()!;
            method_name_is_bigint = true;
            method_name_bigint_src = method_name.str_value;
        } else {
            // After all name-parse branches, the only remaining class-element
            // shape that consumes no further token here is a public FIELD
            // (`name [= expr];`) — `class { x = 1 }` / `class { x; }` /
            // `class { [k] = v }` (computed-key branch already set method_name
            // to a sentinel and advanced past `]`). Field syntax is the
            // universal fallback for valid name forms, so anything else
            // (e.g. `{` as the first class-body token, or stray punctuation)
            // is a SyntaxError. Public field branch (P7, plan 054 §7) fires
            // here for:
            //   - IDENTIFIER/keyword (`class { x = 1 }`)            — lexer on `=`/`;`
            //   - computed key      (`class { [x+y] = v }`)        — lexer on `=`
            //   - STRING            (`class { "x" = 1 }`)         — lexer on `=`
            //   - NUMBER            (`class { 1 = 1 }`)           — lexer on `=`
            //   - BIGINT            (`class { 1n = 1 }`)          — lexer on `=`
            // and is gated by the next token NOT being `(` (a method).
            // The HASH_IDENT case for public fields is N/A — `#x` is a
            // private field, handled at the top of the class-body loop.
            // Reject only if the FIRST class-body token was invalid (e.g. `(`,
            // `,`, EOF).
            if (self.check(TokenType.LPAREN) || self.check(TokenType.EOF_TOKEN)
                || self.is_at_end()) {
                return COMPILE_ERROR~;
            }
            // Continue to the field branch below.
        }

        // A line terminator after the identifier `accessor` cannot be
        // reinterpreted as a second class element after an accessor-field
        // introducer. Resource/accessor proposal syntax is not implemented,
        // so reject this ambiguous form instead of accepting it via ASI.
        if (self.check(TokenType.IDENTIFIER)
            && method_name.str_value.len == 8
            && method_name.str_value[0] == 'a' && method_name.str_value[1] == 'c'
            && method_name.str_value[2] == 'c' && method_name.str_value[3] == 'e'
            && method_name.str_value[4] == 's' && method_name.str_value[5] == 's'
            && method_name.str_value[6] == 'o' && method_name.str_value[7] == 'r'
            && self.lexer.seen_line_term) {
            return COMPILE_ERROR~;
        }

        // Public field branch (P7, plan 054 §7). Triggered when the element
        // has a name (literal or computed-key, public or private-name) and
        // is NOT followed by `(` (i.e. is not a method) and NOT a
        // getter/setter. Identical shape for instance + static fields; the
        // only knob is which `target_ctx` the install goes into and which
        // `target` (proto vs ctor) the install writes to.
        bool is_public_field = !is_constructor
            && !is_getter && !is_setter
            && !is_generator_method && !is_async_method
            && !self.check(TokenType.LPAREN);
        if (is_public_field) {
            // PropName early errors (ES2022 §15.7.1):
            //  - FieldDefinition: PropName == "constructor"  → SyntaxError
            //  - staticFieldDefinition: PropName == "prototype" || "constructor"
            //  - ComputedPropertyName: NO early error (PropName is "")
            // The literal-string form of a computed key (`['constructor']`)
            // is NOT a ComputedPropertyName at this point — its PropName is
            // the string value, so the rule applies and it MUST throw.
            // `name_from_computed_string` captures that exception.
            char[] field_propname = {};
            if (method_name_is_number) {
                char[64] b;
                field_propname = format_field_number_key(method_name_num_value, &b);
            } else if (method_name_is_bigint) {
                int128? parsed = hbigint::parse_bigint_literal(method_name_bigint_src);
                if (catch p_err = parsed) return COMPILE_ERROR~;
                char[48] b;
                field_propname = hbigint::int128_to_radix(parsed, 10, &b);
            } else if (method_name.type == TokenType.STRING) {
                field_propname = method_name.str_value;
            } else {
                field_propname = method_name.str_value;
            }
            if (!has_computed_key) {
                if (str_eq(field_propname, "constructor")) return COMPILE_ERROR~;
                if (is_static && str_eq(field_propname, "prototype")) return COMPILE_ERROR~;
            }

            CompilerContext* target_ctx = is_static ? &static_init_ctx : &field_init_ctx;
            bool* target_has_init = is_static ? &has_static_init : &has_field_init;
            if (!*target_has_init) {
                *target_has_init = true;
                self.ensure_field_init_ctx(target_ctx, is_static);
            }

            // For a computed-key public field, the key expression is
            // evaluated ONCE at class-definition time, in source order
            // interleaved with method-key evaluation. Compile the key
            // expression in this (class-enclosing) context right now so its
            // PUTLEX below runs in the same order as ClassElementEvaluation
            // (§15.7.15 step 6.a.i). Allocating a hidden lexical slot
            // ("#priv:<id>:fkey<N>") keeps the value alive past the install
            // loop and reachable from __field_init__ / __static_init__.
            char[] fkey_slot = "";
            ushort fkey_reg = 0xFFFF;
            if (has_computed_key) {
                uint class_id_f = self.private_scope_depth > 0
                    ? self.private_class_id[self.private_scope_depth - 1]
                    : 0;
                char[96] buf;
                char[16] digits;
                char[] prefix = "#priv:";
                usz pos = 0;
                for (usz i = 0; i < prefix.len && pos < buf.len; i++) buf[pos++] = prefix[i];
                usz dcnt = 0;
                do {
                    digits[dcnt++] = (char)('0' + class_id_f % 10);
                    class_id_f /= 10;
                } while (class_id_f > 0);
                while (dcnt > 0 && pos < buf.len) buf[pos++] = digits[--dcnt];
                char[] suf = ":fkey";
                for (usz i = 0; i < suf.len && pos < buf.len; i++) buf[pos++] = suf[i];
                usz fk_cnt = computed_field_key_count;
                usz dcnt2 = 0;
                do {
                    digits[dcnt2++] = (char)('0' + fk_cnt % 10);
                    fk_cnt /= 10;
                } while (fk_cnt > 0);
                while (dcnt2 > 0 && pos < buf.len) buf[pos++] = digits[--dcnt2];
                char[] fkey_name = self.intern_slot_name(buf[:pos]);
                self.declare_priv_slot(fkey_name);
                fkey_slot = fkey_name;

                if (computed_key_inner_idx == 0xFFFFFFFE) {
                    // Inline key (enclosing is generator/async): re-emit into
                    // the class-enclosing context by simply copying the
                    // already-computed value into a fresh register.
                    fkey_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDREG, (uint)fkey_reg, (uint)computed_key_reg, 0);
                    self.free_reg(computed_key_reg);
                } else {
                    // The key expression was already added to
                    // self.inner_funcs[computed_key_inner_idx] when the
                    // computed-key bracket was parsed (line 614 /
                    // accessor path line 654). CLOSURE + CALL + TOPROPKEY
                    // (in-place ToPropertyKey coercion — must run at class
                    // definition time per ES2022 §15.7.15 step 6.a.i so an
                    // object-key that throws on toString throws NOW, not at
                    // per-instance init time).
                    fkey_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)fkey_reg, computed_key_inner_idx));
                    // CALL convention: this at callee_reg + 1, result into callee_reg.
                    ushort this_slot = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_slot, 0));
                    self.emit_abc(Opcode.CALL, (uint)fkey_reg, (uint)fkey_reg, 0);
                    self.free_reg(this_slot);
                    self.emit_abc(Opcode.TOPROPKEY, (uint)fkey_reg, 0, 0);
                }
                if (computed_key_inner_idx == 0xFFFFFFFE) {
                    // Inline key also needs in-place TOPROPKEY.
                    self.emit_abc(Opcode.TOPROPKEY, (uint)fkey_reg, 0, 0);
                }
                uint fkey_name_idx = self.add_string_constant(fkey_slot);
                self.emit_a_bc(Opcode.PUTLEX, (uint)fkey_reg, fkey_name_idx);
                self.free_reg(fkey_reg);
                computed_field_key_count++;
            }

            // The field initializer value: assigned via `=` (or undefined).
            // ES2022 §15.7.10 step 7: an anonymous function definition
            // initializer gets SetFunctionName with the field name — the
            // *literal* key for static-name fields, the *value* (always the
            // empty string for computed keys) for computed fields. We pass
            // the literal name for both; the only observable difference is
            // that empty-named function names come out empty (matching §B.3.4
            // step 1.a which says `let key = ? evaluation of PropertyName;`
            // for computed keys — and PropertyName evaluation of `[expr]` is
            // the empty string per §12.2.6.9). ToPropertyKey on the key in
            // step 8.b does not feed the function name.
            bool use_inferred = !has_computed_key;
            if (use_inferred) {
                target_ctx.has_inferred_name = true;
                if (field_propname.len < 128) {
                    for (usz i = 0; i < field_propname.len; i++) {
                        target_ctx.inferred_name_buf[i] = field_propname[i];
                    }
                    target_ctx.inferred_name_len = (ushort)field_propname.len;
                } else {
                    target_ctx.inferred_name_len = 0;
                }
            }

            ushort init_reg;
            if (self.match(TokenType.ASSIGN)) {
                init_reg = target_ctx.assignment_expr()!;
            } else {
                init_reg = target_ctx.alloc_reg();
                target_ctx.emit_abc(Opcode.LDUNDEF, (uint)init_reg, 0, 0);
            }

            if (use_inferred) {
                target_ctx.has_inferred_name = false;
                target_ctx.inferred_name_len = 0;
            }

            // Field terminator: explicit `;`, the class body's `}`, or ASI at
            // a line terminator (ES2024 §12.10.1). A same-line token with no
            // separator (`accessor x = 1`) is a SyntaxError.
            target_ctx.expect_semicolon_or_asi()!;

            // The actual install goes into the init function:
            //   __field_init__:  this[propname] = init_reg;   (WEC, own)
            //   __static_init__: ctor[propname] = init_reg;
            // Use INITPROP (CreateDataPropertyOrThrow semantics — WEC own,
            // no prototype-chain walk, no setters triggered). For computed
            // keys, the key value is read from the hidden slot set above.
            ushort this_reg = target_ctx.alloc_reg();
            target_ctx.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_reg, 0));
            ushort key_reg = target_ctx.alloc_reg();
            if (has_computed_key) {
                target_ctx.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg,
                    target_ctx.add_string_constant(fkey_slot)));
            } else if (method_name_is_number) {
                uint key_idx = target_ctx.add_number_constant(method_name_num_value);
                target_ctx.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (method_name_is_bigint) {
                uint key_idx = target_ctx.add_bigint_constant(method_name_bigint_src)!;
                target_ctx.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (method_name.type == TokenType.STRING) {
                uint key_idx = target_ctx.add_string_constant(method_name.str_value);
                target_ctx.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else {
                uint key_idx = target_ctx.add_string_constant(field_propname);
                target_ctx.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            }
            // TOPROPKEY in-place so a symbol-coercing key doesn't leak the
            // coercion through a later GETPROP. Symmetric with object-literal
            // emission.
            target_ctx.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
            target_ctx.emit_abc(Opcode.INITPROP, (uint)this_reg, (uint)key_reg, (uint)init_reg);
            target_ctx.free_reg(key_reg);
            target_ctx.free_reg(this_reg);
            target_ctx.free_reg(init_reg);

            // Record a pseudo-method entry so the install loop (after the
            // class body, where computed key values are bound into the class
            // env in source order) handles computed-key install. For
            // non-computed public fields, the key is a literal constant
            // known at compile time; the install loop uses the literal-name
            // path and `is_field_key` is unnecessary — skip the entry.
            if (has_computed_key && method_count < MAX_CLASS_METHODS) {
                methods[method_count].name = {};
                methods[method_count].inner_idx = 0xFFFFFFFF;
                methods[method_count].is_static = is_static;
                methods[method_count].is_getter = false;
                methods[method_count].is_setter = false;
                methods[method_count].name_is_number = false;
                methods[method_count].name_is_bigint = false;
                methods[method_count].computed_key_inner_idx = 0xFFFFFFFF;
                methods[method_count].computed_key_reg = 0xFFFF;
                methods[method_count].is_private = false;
                methods[method_count].is_field_key = true;
                methods[method_count].field_key_slot_name = fkey_slot;
                method_count++;
            }

            if (is_static) { static_field_count++; } else { field_count++; }
            continue;
        }

        // Compile the method as an inner function
        // Save and restore is_constructable
        bool saved_constructable = self.is_constructable;

        if (is_constructor) {
            self.is_constructable = true;
        } else {
            self.is_constructable = false;
        }

        // ES2015 §14.5.13: starred methods cannot be constructors, getters, or
        // setters. Catch those before compile_inner_function so we get a clean
        // compile error instead of a miscompiled function.
        if (is_generator_method && (is_constructor || is_getter || is_setter)) {
            return COMPILE_ERROR~;
        }

        // ES2017 §14.6: async methods cannot be constructors, getters, or
        // setters either (`async constructor()`, `async get x()` are
        // SyntaxErrors).
        if (is_async_method && (is_constructor || is_getter || is_setter)) {
            return COMPILE_ERROR~;
        }

        // Set the generator/async flags to exactly this method's own kind so
        // compile_inner_function propagates them into the method body; the
        // saved flags are restored right after so the next sibling element
        // (and the enclosing context) do not inherit them. Assign (not just
        // set-on-true): a plain method defined inside a generator/async body
        // must NOT inherit the enclosing function's flags.
        self.is_generator = is_generator_method;
        self.is_user_generator = is_generator_method;
        self.is_async = is_async_method;

        // ES2015 §14.5.13: getter/setter methods in class bodies have a name
        // prefixed with "get " or "set " (matching object literal semantics).
        // For a computed key ([expr]) the name is the empty string per spec.
        // The constructor method's name is special — per ES2015 §14.5.14
        // ClassDefinitionEvaluation + §14.3.7 DefineMethod, the constructor's
        // name is the className (passed via DefineMethod).  For an anonymous
        // class, that means the constructor's name is "" (per spec).
        char[128] method_name_buf;
        usz method_name_len = 0;
        if (is_private_member) {
            // Private methods/accessors: `.name` is "#foo" / "get #foo" /
            // "set #foo" (the hash is part of the name — P3/P4).
            char[] priv_prefix = is_getter ? "get #" : (is_setter ? "set #" : "#");
            usz priv_name_len = priv_member_name.len;
            if (priv_prefix.len + priv_name_len < 128) {
                for (usz i = 0; i < priv_prefix.len; i++) method_name_buf[i] = priv_prefix[i];
                for (usz i = 0; i < priv_name_len; i++) method_name_buf[priv_prefix.len + i] = priv_member_name[i];
                method_name_len = priv_prefix.len + priv_name_len;
            }
        } else if (is_constructor) {
            // Constructor's name = the runtime-visible className (not the
            // internal "*default*" binding name for default-exported
            // classes). Empty for an anonymous class expression.
            if (ctor_runtime_name.len < 128 && !class_has_static_name) {
                for (usz i = 0; i < ctor_runtime_name.len; i++) method_name_buf[i] = ctor_runtime_name[i];
                method_name_len = ctor_runtime_name.len;
            }
        } else if (has_computed_key) {
            // Leave name empty — the actual key is computed at class evaluation time.
            method_name_len = 0;
        } else if (is_getter || is_setter) {
            char[] prefix = is_getter ? "get " : "set ";
            usz prop_len = method_name.str_value.len;
            if (prefix.len + prop_len < 128) {
                for (usz i = 0; i < prefix.len; i++) method_name_buf[i] = prefix[i];
                for (usz i = 0; i < prop_len; i++) method_name_buf[prefix.len + i] = method_name.str_value[i];
                method_name_len = prefix.len + prop_len;
            }
        } else {
            usz prop_len = method_name.str_value.len;
            if (prop_len < 128) {
                for (usz i = 0; i < prop_len; i++) method_name_buf[i] = method_name.str_value[i];
                method_name_len = prop_len;
            }
        }

        // Capture the plain (undecorated) method name NOW, before compiling
        // the body below: an escaped identifier's str_value borrows the
        // lexer's shared ident_buf scratch, which the method's own params
        // and nested escaped identifiers will overwrite. `methods[]` outlives
        // this element (read again once every sibling has been parsed), so
        // it must not hold a raw token borrow.
        char[] method_key_name = self.intern_slot_name(method_name.str_value);

        // Static methods' `super.x` resolves HomeObject = the constructor
        // (__static_super__), not the prototype.
        bool saved_super_is_static_method = self.super_is_static_method;
        self.super_is_static_method = is_static;
        CompiledFunction* inner = self.compile_inner_function(method_name_buf[:method_name_len], false, class_elem_src_start, true)!;
        self.super_is_static_method = saved_super_is_static_method;

        self.is_constructable = saved_constructable;
        self.is_generator = saved_is_generator;
        self.is_user_generator = saved_is_user_generator;
        self.is_async = saved_is_async;

        // Add to inner functions table
        uint inner_idx = self.add_inner_func(inner);

        if (is_constructor) {
            ctor_inner_idx = inner_idx;
        } else if (method_count < MAX_CLASS_METHODS) {
            methods[method_count].name = method_key_name;
            methods[method_count].inner_idx = inner_idx;
            methods[method_count].is_static = is_static;
            methods[method_count].is_getter = is_getter;
            methods[method_count].is_setter = is_setter;
            methods[method_count].name_is_number = method_name_is_number;
            methods[method_count].name_num_value = method_name_num_value;
            methods[method_count].name_is_bigint = method_name_is_bigint;
            methods[method_count].name_bigint_src = method_name_bigint_src;
            methods[method_count].computed_key_inner_idx = computed_key_inner_idx;
            methods[method_count].computed_key_reg = (uint)computed_key_reg;
            methods[method_count].is_private = is_private_member;
            if (is_private_member) {
                PrivateNameEntry* pe = self.resolve_private_name(priv_member_name)!;
                methods[method_count].priv_slot_name = pe.slot_name;
            }
            if (is_static && !is_private_member && method_key_name == "name") {
                class_has_static_name = true;
            }
            method_count++;
        }
    }

    // Finish __field_init__: implicit `return;` after the last field. The
    // resulting CompiledFunction is stored as a raw pointer on the
    // constructor (below) rather than an inner_funcs index — it was compiled
    // in THIS (class-enclosing) context, a different inner-function table
    // than the constructor's own, so an index would be meaningless there.
    CompiledFunction* field_init_func = null;
    if (has_field_init) {
        field_init_ctx.emit_simple(Opcode.POP_LEX);
        field_init_ctx.emit_simple(Opcode.RETUNDEF);
        // finish() already registers the CompiledFunction with the heap's
        // teardown tracking — no extra track_compiled_func here.
        field_init_func = field_init_ctx.finish()!;
    }
    (void)field_count;

    // Finish __static_init__ (P5): implicit `return;` after the last static
    // field. Compiled the same way as __field_init__, but invoked directly
    // by COMPILER-EMITTED bytecode right after class evaluation (below) with
    // `this` = the constructor — no VM construct-path hook is needed since
    // static fields initialize once, not per instance.
    CompiledFunction* static_init_func = null;
    if (has_static_init) {
        static_init_ctx.emit_simple(Opcode.POP_LEX);
        static_init_ctx.emit_simple(Opcode.RETUNDEF);
        static_init_func = static_init_ctx.finish()!;
    }
    (void)static_field_count;

    self.expect(TokenType.RBRACE)!;
    // A `}` closing a ClassBody is a statement/declaration boundary only for
    // class declarations. Class expressions (`x = class {}/re/`) sit inside a
    // larger expression, so a following `/` is division; suppress the hint.
    if (!is_expr) {
        self.lexer.note_block_close();
    }
    // Capture the end position of the class (after `}`) for source retention.
    uint class_src_end = self.lexer.pos;

    // If no constructor was specified, create a default one.
    // ES2015 §14.1.20 SetFunctionName step 6.d: if the class has a static
    // `name` method, it defines an own "name" property on the constructor
    // that overrides the auto-set one. Suppress the inferred name so the
    // static method installation can succeed.
    // Default constructor (no explicit one in the class body) inherits the
    // runtime-visible className as `.name` (not the internal "*default*"
    // binding name for default-exported classes).
    char[] ctor_class_name = ctor_runtime_name;
    if (class_has_static_name) ctor_class_name = {};
    if (ctor_inner_idx == 0xFFFFFFFF) {
        heap::Heap* hp = (heap::Heap*)self.heap;
        CompiledFunction*? ctor_func_raw = make_default_constructor(hp, self.has_super_binding, ctor_class_name);
        if (catch err = ctor_func_raw) {
            return COMPILE_ERROR~;
        }
        CompiledFunction* ctor_func = ctor_func_raw;
        // Track for heap cleanup
        hp.track_compiled_func((void*)ctor_func);
        ctor_inner_idx = self.add_inner_func(ctor_func);
    }

    // Mark the constructor (explicit or default) as a class constructor:
    // non-configurable .prototype (§14.5.14 step 25) and TypeError when
    // called without `new` (§10.2.1 step 2).
    // Derived constructors (has_super_binding) get is_derived_ctor so the VM
    // can enforce §9.2.2 step 13.c: non-object non-undefined return → TypeError.
    if (ctor_inner_idx < self.inner_func_count) {
        self.inner_funcs[ctor_inner_idx].flags.is_class_ctor = true;
        if (self.has_super_binding) {
            self.inner_funcs[ctor_inner_idx].flags.is_derived_ctor = true;
        }
        // Private class fields (ES2022): record where the VM construct path
        // finds __field_init__ and the brand's lex-scope binding name, as
        // raw pointers (self-contained — see the CompiledFunction field docs
        // in bytecode.c3 for why these are not pool indices).
        self.inner_funcs[ctor_inner_idx].field_init_func = field_init_func;
        self.inner_funcs[ctor_inner_idx].brand_name_hstr = has_brand
            ? self.intern_private_binding_name(brand_slot_name) : null;
    }

    // Retain the entire class source text on the constructor function so that
    // Function.prototype.toString returns the full `class ... { }` text when
    // called on the class (ES2019 §19.2.3.5 / §14.6.3 ClassDefinitionEvaluation).
    if (class_src_start != 0xFFFFFFFF
            && class_src_start < (uint)self.lexer.source.len
            && ctor_inner_idx < self.inner_func_count) {
        CompiledFunction* ctor_cf = self.inner_funcs[ctor_inner_idx];
        uint src_end = class_src_end;
        if (src_end > (uint)self.lexer.source.len) src_end = (uint)self.lexer.source.len;
        uint slen = src_end > class_src_start ? (src_end - class_src_start) : 0;
        if (slen > 0) {
            char* src_heap = (char*)alloc::malloc_try(mem, (sz)((usz)slen + 1)) ?? null;
            if (src_heap != null) {
                for (uint i = 0; i < slen; i++) src_heap[i] = self.lexer.source[class_src_start + i];
                src_heap[slen] = 0;
                if (ctor_cf.src_ptr != null) mem::free(ctor_cf.src_ptr);
                ctor_cf.src_ptr = src_heap;
                ctor_cf.src_len = slen;
            }
        }
    }

    // Emit CLOSURE for the constructor
    ushort ctor_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)ctor_reg, ctor_inner_idx));

    // Bind __static_super__ = the constructor itself, for static methods'
    // `super.x` (HomeObject = constructor, per §13.3.7.1).
    self.emit_abc(Opcode.LDREG, (uint)static_super_reg, (uint)ctor_reg, 0);
    self.emit_a_bc(Opcode.PUTLEX, (uint)static_super_reg, static_super_name_idx);

    // Set up prototype
    ushort proto_reg = self.alloc_reg();
    uint proto_name_idx = self.add_string_constant("prototype");
    {
        ushort proto_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
        self.emit_abc(Opcode.GETPROP, (uint)proto_reg, (uint)ctor_reg, (uint)proto_key_reg);
        self.free_reg(proto_key_reg);
    }

    // For classes without extends, bind __super__ = proto_reg (C.prototype).
    // Methods use super_is_home_object=true so GetSuperBase = GETPROTO(C.prototype)
    // = Object.prototype, matching the spec (HomeObject = C.prototype, super = Object.prototype).
    if (base_reg == MAX_REGISTERS) {
        self.emit_abc(Opcode.LDREG, (uint)super_reg, (uint)proto_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)super_reg, super_name_idx);
    }

    // Private class fields (ES2022): allocate a fresh hidden symbol for every
    // private name declared in this class body (own scope only — nested
    // classes push/pop their own), and the class brand if any private member
    // exists. Each NEW_PRIV_SYM result is stored into its compiler-managed
    // lexical slot (declared during the pre-scan) so method/field-init
    // bodies resolve it via GETVAR, exactly like __super__.  Fresh per class
    // *evaluation* — this is what gives per-evaluation-freshness for free.
    {
        uint priv_scope_begin = self.private_scope_depth > 0
            ? self.private_scope_start[self.private_scope_depth - 1] : 0;
        for (uint pi = priv_scope_begin; pi < self.private_name_table.count; pi++) {
            uint desc_idx = self.add_string_constant(self.private_name_table.entries[pi].name);
            ushort sym_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.NEW_PRIV_SYM, (uint)sym_reg, desc_idx);
            self.emit_a_bc(Opcode.PUTLEX, (uint)sym_reg,
                self.add_string_constant(self.private_name_table.entries[pi].slot_name));
            self.free_reg(sym_reg);
        }
        if (has_brand) {
            uint brand_desc_idx = self.add_string_constant("brand");
            ushort brand_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.NEW_PRIV_SYM, (uint)brand_reg, brand_desc_idx);
            self.emit_a_bc(Opcode.PUTLEX, (uint)brand_reg,
                self.add_string_constant(brand_slot_name));
            self.free_reg(brand_reg);
        }
        if (has_static_brand) {
            // P5: the static brand is stamped on the CONSTRUCTOR object
            // itself, right here in the class-evaluation bytecode (ctor_reg
            // is already live) — unlike the instance brand, which the VM
            // construct path stamps per-instance, the static brand only
            // needs to be set once, now.
            uint sbrand_desc_idx = self.add_string_constant("sbrand");
            ushort sbrand_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.NEW_PRIV_SYM, (uint)sbrand_reg, sbrand_desc_idx);
            self.emit_a_bc(Opcode.PUTLEX, (uint)sbrand_reg,
                self.add_string_constant(static_brand_slot_name));
            self.emit_abc(Opcode.ADD_BRAND, (uint)ctor_reg, (uint)sbrand_reg, 0);
            self.free_reg(sbrand_reg);
        }
    }

    // If extends, set proto.__proto__ = Base.prototype (or null for `extends null`).
    // ES2015 §15.7.14 step 5.e: if superclass is null, protoParent=null,
    // constructorParent=%FunctionPrototype% (constructor already inherits it by default).
    if (base_reg != MAX_REGISTERS) {
        ushort base_proto_reg = self.alloc_reg();
        // Emit a runtime null check: if (base === null) goto null_branch
        ushort null_cond_reg = self.alloc_reg();
        ushort null_lit_reg  = self.alloc_reg();
        self.emit_abc(Opcode.LDNULL, (uint)null_lit_reg, 0, 0);
        self.emit_abc(Opcode.SEQ, (uint)null_cond_reg, (uint)base_reg, (uint)null_lit_reg);
        self.free_reg(null_lit_reg);
        uint null_branch_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)null_cond_reg);
        self.free_reg(null_cond_reg);

        // Non-null path: base_proto_reg = Base.prototype
        {
            ushort base_proto_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)base_proto_key_reg, proto_name_idx));
            self.emit_abc(Opcode.GETPROP, (uint)base_proto_reg, (uint)base_reg, (uint)base_proto_key_reg);
            self.free_reg(base_proto_key_reg);
        }
        // ES2015 §14.5.14 step 5.g.ii-iv: Type(protoParent) must be Object or Null.
        self.emit_abc(Opcode.CHK_PROT, (uint)base_proto_reg, 0, 0);
        self.emit_abc(Opcode.SETPROTO, (uint)proto_reg, (uint)base_proto_reg, 0);
        // ctor.__proto__ = Base (static inheritance chain)
        self.emit_abc(Opcode.SETPROTO, (uint)ctor_reg, (uint)base_reg, 0);
        uint skip_null_jump = self.emit_jump(Opcode.JUMP);

        // Null path: proto.__proto__ = null; ctor.__proto__ stays %FunctionPrototype%
        self.patch_jump(null_branch_jump);
        self.emit_abc(Opcode.LDNULL, (uint)base_proto_reg, 0, 0);
        self.emit_abc(Opcode.SETPROTO, (uint)proto_reg, (uint)base_proto_reg, 0);
        // ctor does NOT inherit from null: it keeps Function.prototype (set by CLOSURE).

        self.patch_jump(skip_null_jump);
        self.free_reg(base_proto_reg);
    }

    // Install methods on prototype or constructor (static)
    for (ushort mi = 0; mi < method_count; mi++) {
        uint mi_idx = methods[mi].inner_idx;
        ushort method_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)method_reg, mi_idx));

        ushort target_reg = methods[mi].is_static ? ctor_reg : proto_reg;

        // Get the key register — either from computed key expression, static
        // name, or (P3/P4) the private name's own runtime symbol slot.
        ushort key_reg;
        if (methods[mi].is_private) {
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg,
                self.add_string_constant(methods[mi].priv_slot_name)));
        } else if (methods[mi].computed_key_inner_idx == 0xFFFFFFFE) {
            // Inline-compiled computed key (yield/await in generator/async).
            // The expression was compiled inline during parsing and the result
            // register was stored in computed_key_reg.
            key_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)key_reg, methods[mi].computed_key_reg, 0);
        } else if (methods[mi].computed_key_inner_idx != 0xFFFFFFFF) {
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
            // Non-computed key: use the stored name.  For NUMBER tokens, emit a
            // number constant so the runtime get_prop_key() converts it to the
            // proper string representation (e.g. 0x10 → "16"). BIGINT tokens
            // follow the same pattern (e.g. `1n() {}` → key "1").
            uint key_idx;
            if (methods[mi].name_is_number) {
                key_idx = self.add_number_constant(methods[mi].name_num_value);
            } else if (methods[mi].name_is_bigint) {
                key_idx = self.add_bigint_constant(methods[mi].name_bigint_src)!;
            } else {
                key_idx = self.add_string_constant(methods[mi].name);
            }
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
        }

        if (methods[mi].is_getter) {
            self.emit_abc(Opcode.CLASS_INITGET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else if (methods[mi].is_setter) {
            self.emit_abc(Opcode.CLASS_INITSET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else {
            // Both static and instance methods use CLASS_INITPROP
            // (DefinePropertyOrThrow semantics with non-enumerable flags).
            // Per ES2015 §14.5.14 step 9, public class methods are
            // {writable:true, enumerable:false, configurable:true}; private
            // methods (hidden-symbol key) are additionally non-writable and
            // non-configurable per ES2022 §7.3.28 — the CLASS_INITPROP
            // handler picks the flag set from key.is_hidden().
            self.emit_abc(Opcode.CLASS_INITPROP, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        }

        self.free_reg(key_reg);
        self.free_reg(method_reg);
    }

    self.free_reg(proto_reg);

    // P5: CLOSURE __static_init__ captures the CURRENT lex_env (still the
    // classScope pushed at the start of class_decl, with className bound).
    // Per ES2022 §15.7.14 ClassDefinitionEvaluation, static field initializers
    // must be able to resolve the class name — so the className binding
    // (initially TDZ from INITTZ at the top of class_decl/class_expr) is
    // initialized with the constructor HERE, before the matching POP_LEX
    // and the CALL that runs the initializer.  Without this, `static #g =
    // (Object.preventExtensions(C), "Test262")` throws ReferenceError on `C`
    // because the classScope binding is still TDZ when the initializer runs.
    // Gated on `class_name_reg` only — the string-constant index may
    // legitimately be 0 (the first string added to the pool).
    if (has_static_init) {
        // finish() already registers static_init_func with the heap's
        // teardown tracking — no extra track_compiled_func here (double-free
        // if called twice, see field_init_func above).
        uint static_init_idx = self.add_inner_func(static_init_func);
        ushort si_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)si_reg, static_init_idx));
        // Initialize the class-name binding inside the classScope while it
        // is still the current lex scope (the CLOSURE above just captured
        // it for static_init, methods on the class already captured it
        // earlier).  These three instructions (LDREG, PUTLEX_C, POP_LEX)
        // MUST be emitted as a block right before the CALL — CLOSURE must
        // come first (so it captures classScope), and the CALL must come
        // last (so className has been initialized in static_init's view of
        // the scope).  When `class_name_reg == MAX_REGISTERS`, the class
        // had no name (anonymous class expression) and neither LDREG nor
        // PUTLEX_C nor POP_LEX are emitted; the caller never pushed a
        // classScope for the anonymous case so there is nothing to pop.
        if (class_name_reg != MAX_REGISTERS) {
            self.emit_abc(Opcode.LDREG, (uint)class_name_reg, (uint)ctor_reg, 0);
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)class_name_reg, class_name_str_idx);
            self.emit_simple(Opcode.POP_LEX);
        }
        ushort si_this_slot = self.alloc_reg();  // must be si_reg + 1
        self.emit_abc(Opcode.LDREG, (uint)si_this_slot, (uint)ctor_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)si_reg, (uint)si_reg, 0);
        self.free_reg(si_this_slot);
        self.free_reg(si_reg);
    } else if (class_name_reg != MAX_REGISTERS) {
        // No static initializer, but the classScope className binding still
        // needs to be initialized with the constructor (so e.g. methods
        // referenced via `this.constructor` after a `super()`-without-extends
        // class body resolve correctly) and the scope popped (so the outer
        // binding installation doesn't double-pop).  PUSH_LEX/POP_LEX are
        // balanced at module level.
        self.emit_abc(Opcode.LDREG, (uint)class_name_reg, (uint)ctor_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX_C, (uint)class_name_reg, class_name_str_idx);
        self.emit_simple(Opcode.POP_LEX);
    }

    // Restore class body state
    self.in_class_body = saved_in_class_body;
    self.has_super_binding = saved_has_super;
    self.super_is_home_object = saved_super_is_home;
    self.pop_private_scope();

    return ctor_reg;
}
