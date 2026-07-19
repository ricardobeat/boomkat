module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Class parsing (ES6)
// ============================================================================

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
        char* name_heap = (char*)hp.alloc_func(hp.heap_udata, (usz)class_name.len + 1);
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
fn void? CompilerContext.class_declaration(&self) {
    // Capture class source start before consuming `class` keyword.
    self.lexer.refresh_token_start();
    uint class_decl_src_start = self.lexer.token_start;
    self.expect(TokenType.CLASS)!;
    // Per ES2024 §15.7.1, BindingIdentifier may be `await` (in non-module)
    // or `yield` (in non-generator). Accept these contextual keywords.
    Token name_tok;
    TokenType name_tt = self.peek_type();
    if (name_tt == TokenType.IDENTIFIER) {
        name_tok = self.advance()!;
    } else if ((name_tt == TokenType.AWAIT && !self.is_module) ||
               (name_tt == TokenType.YIELD && !self.is_generator)) {
        name_tok = self.advance()!;
    } else {
        return COMPILE_ERROR~;
    }

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
    ushort class_reg = self.declare_var(name_tok.str_value, LET);
    uint class_name_idx = self.add_string_constant(name_tok.str_value);

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
    // constructor from inside method bodies.
    ushort ctor_reg = self.parse_class_tail_with_name(name_tok.str_value, class_decl_src_start, false)!;

    // Initialize the classScope's immutable binding with the constructor value
    // (overwriting the TDZ placeholder).
    self.emit_abc(Opcode.LDREG, (uint)class_reg, (uint)ctor_reg, 0);
    self.emit_a_bc(Opcode.PUTLEX_C, (uint)class_reg, class_name_idx);

    // Pop the classScope — methods retain it via CLOSURE capture.
    self.emit_simple(Opcode.POP_LEX);

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
        (class_name_tt == TokenType.AWAIT && !self.is_module) ||
        (class_name_tt == TokenType.YIELD && !self.is_generator);
    if (is_valid_class_name) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
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
    // has empty .name (per ES2015 anonymous class expression).
    ushort ctor_reg = self.parse_class_tail_with_name(name, class_expr_src_start, true)!;

    // For named class expressions, initialize the classScope's immutable
    // binding with the constructor, then pop classScope.  Methods retain it
    // via CLOSURE capture, so `C` inside methods resolves to the class.
    if (has_name) {
        self.emit_abc(Opcode.LDREG, (uint)name_reg, (uint)ctor_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX_C, (uint)name_reg, class_name_idx);
        self.emit_simple(Opcode.POP_LEX);
    }

    return ctor_reg;
}

/// Parse the tail of a class: optional `extends` clause + class body.
/// Returns the register holding the constructor function.
/// `class_name`: when non-empty, the default constructor inherits this name
/// as its `.name` property (ES2015 §14.5.14 + SetFunctionName).
fn ushort? CompilerContext.parse_class_tail_with_name(&self, char[] class_name, uint class_src_start = 0xFFFFFFFF, bool is_expr = false) {
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
        for (uint pbi = priv_scope_begin0; pbi < self.private_name_count; pbi++) {
            if (self.private_names[pbi].is_static) {
                if (!has_static_brand) {
                    has_static_brand = true;
                    static_brand_slot_name = self.declare_class_static_brand();
                }
                self.private_names[pbi].brand_slot_name = static_brand_slot_name;
            } else {
                if (!has_brand) {
                    has_brand = true;
                    brand_slot_name = self.declare_class_brand();
                }
                self.private_names[pbi].brand_slot_name = brand_slot_name;
            }
        }
    }

    // Parse class body
    self.expect(TokenType.LBRACE)!;

    // Track methods found in the class body
    ClassMethod[MAX_CLASS_METHODS] methods;
    ushort method_count = 0;

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

            CompilerContext* target_ctx = is_static ? &static_init_ctx : &field_init_ctx;
            bool* target_has_init = is_static ? &has_static_init : &has_field_init;
            if (!*target_has_init) {
                *target_has_init = true;
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

            ushort init_reg;
            if (self.match(TokenType.ASSIGN)) {
                init_reg = target_ctx.assignment_expr()!;
            } else {
                init_reg = target_ctx.alloc_reg();
                target_ctx.emit_abc(Opcode.LDUNDEF, (uint)init_reg, 0, 0);
            }

            // Optional semicolon between field declarations; a missing one is
            // ASI (the outer loop's `while` condition/`RBRACE` check and the
            // next iteration's own token dispatch tolerate the omission the
            // same way method declarations do).
            target_ctx.match(TokenType.SEMICOLON);

            // this[#name_sym] = init_reg — PrivateFieldAdd bypasses setters,
            // proxies, and the extensibility check (INITPROP_PRIV). For a
            // static field, `this` inside __static_init__ is bound to the
            // constructor (see __static_init__'s CALL emission below).
            ushort this_reg = target_ctx.alloc_reg();
            target_ctx.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_reg, 0));
            ushort key_reg = target_ctx.alloc_reg();
            target_ctx.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg,
                target_ctx.add_string_constant(entry.slot_name)));
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
        bool saved_is_async = self.is_async;
        // ES2017 §14.6: async-method shorthand — `async m() { await ... }`.
        // `async` is not a keyword; match_async_method_prefix consumes it only
        // when it is a modifier (followed on the same line by a method name),
        // so `async() {}` still parses as a method named "async".
        bool is_async_method = self.match_async_method_prefix();
        bool is_generator_method = self.match(TokenType.STAR);
        // Async generator methods (`async *m() {}`) are not supported.
        if (is_async_method && is_generator_method) {
            return self.fail("async generator methods are not supported")~;
        }

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

        // Check for computed key [expr]
        bool has_computed_key = false;
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
                Token str_tok = self.advance()!;
                self.expect(TokenType.RBRACKET)!;
                has_computed_key = false;
                // Reuse the IDENTIFIER / string / static-prototype early-error check
                // below by treating the string as a fixed-name method token.
                method_name = str_tok;
                // Fall through to the static-prototype check below.
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
        } else {
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
            // Constructor's name = className (empty for anonymous class)
            if (class_name.len < 128 && !class_has_static_name) {
                for (usz i = 0; i < class_name.len; i++) method_name_buf[i] = class_name[i];
                method_name_len = class_name.len;
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

        // Static methods' `super.x` resolves HomeObject = the constructor
        // (__static_super__), not the prototype.
        bool saved_super_is_static_method = self.super_is_static_method;
        self.super_is_static_method = is_static;
        CompiledFunction* inner = self.compile_inner_function(method_name_buf[:method_name_len], false, class_elem_src_start, true)!;
        self.super_is_static_method = saved_super_is_static_method;

        self.is_constructable = saved_constructable;
        self.is_generator = saved_is_generator;
        self.is_async = saved_is_async;

        // Add to inner functions table
        uint inner_idx = self.add_inner_func(inner);

        if (is_constructor) {
            ctor_inner_idx = inner_idx;
        } else if (method_count < MAX_CLASS_METHODS) {
            methods[method_count].name = method_name.str_value;
            methods[method_count].inner_idx = inner_idx;
            methods[method_count].is_static = is_static;
            methods[method_count].is_getter = is_getter;
            methods[method_count].is_setter = is_setter;
            methods[method_count].name_is_number = method_name_is_number;
            methods[method_count].name_num_value = method_name_num_value;
            methods[method_count].computed_key_inner_idx = computed_key_inner_idx;
            methods[method_count].computed_key_reg = (uint)computed_key_reg;
            methods[method_count].is_private = is_private_member;
            if (is_private_member) {
                PrivateNameEntry* pe = self.resolve_private_name(priv_member_name)!;
                methods[method_count].priv_slot_name = pe.slot_name;
            }
            if (is_static && !is_private_member && method_name.str_value == "name") {
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
    char[] ctor_class_name = class_name;
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
        for (uint pi = priv_scope_begin; pi < self.private_name_count; pi++) {
            uint desc_idx = self.add_string_constant(self.private_names[pi].name);
            ushort sym_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.NEW_PRIV_SYM, (uint)sym_reg, desc_idx);
            self.emit_a_bc(Opcode.PUTLEX, (uint)sym_reg,
                self.add_string_constant(self.private_names[pi].slot_name));
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
            // proper string representation (e.g. 0x10 → "16").
            uint key_idx;
            if (methods[mi].name_is_number) {
                key_idx = self.add_number_constant(methods[mi].name_num_value);
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

    // P5: run __static_init__ once, right after class evaluation, with
    // `this` = the constructor (spec: static field initializers evaluate
    // during ClassDefinitionEvaluation, not per-instance — unlike instance
    // fields, this needs no VM construct-path hook; it's plain
    // compiler-emitted bytecode using the already-live ctor_reg).
    if (has_static_init) {
        // finish() already registers static_init_func with the heap's
        // teardown tracking — no extra track_compiled_func here (double-free
        // if called twice, see field_init_func above).
        uint static_init_idx = self.add_inner_func(static_init_func);
        ushort si_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)si_reg, static_init_idx));
        ushort si_this_slot = self.alloc_reg();  // must be si_reg + 1
        self.emit_abc(Opcode.LDREG, (uint)si_this_slot, (uint)ctor_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)si_reg, (uint)si_reg, 0);
        self.free_reg(si_this_slot);
        self.free_reg(si_reg);
    }

    // Restore class body state
    self.in_class_body = saved_in_class_body;
    self.has_super_binding = saved_has_super;
    self.super_is_home_object = saved_super_is_home;
    self.pop_private_scope();

    return ctor_reg;
}
