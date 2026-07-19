module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;


// ============================================================================
// Private class members (ES2022) — name resolution
//
// Each private name (`#foo`) declared in a class body gets a compiler-managed
// lexical variable in the scope enclosing the class (declared the same way
// as `__super__`, see class.c3), holding the per-evaluation runtime hidden
// symbol.  A stack of PrivateNameEntry records — scoped by class nesting —
// backs `resolve_private_name`; there is no get-or-create, so a reference to
// an undeclared name is a compile-time SyntaxError.
// ============================================================================

/// Monotonic compile-time id handed to each class body, embedded in its
/// slot binding names ("#priv:<id>:foo") so that sibling classes in the
/// same scope and nested classes never share a binding. Per-EVALUATION
/// freshness of the symbols themselves comes from NEW_PRIV_SYM at runtime;
/// this id only keeps compile-time bindings distinct.
uint g_private_class_id = 0;

/// Build the lexical binding name for a private slot into `buf`:
/// "#priv:<id>:<name>". Returns the filled prefix of `buf`.
fn char[] format_private_slot_name(char[] buf, uint class_id, char[] name) {
    char[] prefix = "#priv:";
    usz pos = 0;
    for (usz i = 0; i < prefix.len && pos < buf.len; i++) buf[pos++] = prefix[i];
    char[12] digits;
    usz dcount = 0;
    do {
        digits[dcount++] = (char)('0' + class_id % 10);
        class_id /= 10;
    } while (class_id > 0);
    while (dcount > 0 && pos < buf.len) buf[pos++] = digits[--dcount];
    if (pos < buf.len) buf[pos++] = ':';
    for (usz i = 0; i < name.len && pos < buf.len; i++) buf[pos++] = name[i];
    return buf[:pos];
}

/// Intern a slot binding name and return its stable byte slice. Interned
/// HString data outlives every CompilerContext, so the slice is safe to
/// store in PrivateNameEntry and to pass to declare_priv_slot's tracker.
fn char[] CompilerContext.intern_slot_name(&self, char[] slot_name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(slot_name);
    char[] data = hstr.get_data();
    return data;
}

/// Register a private-name slot binding (`#priv:<id>:name` or `#priv:<id>:
/// brand`/`sbrand`) in the CURRENT (class-enclosing) context WITHOUT
/// allocating a register or pushing to scope_stack.
///
/// Why: these bindings are only ever accessed via GETVAR by name from the
/// class's __field_init__ and method bodies — the class-enclosing scope
/// never reads them by register. declare_var would consume a register per
/// slot, exhausting the 512-register limit for classes with ~500+ private
/// fields (the test262 start-unicode-* / part-unicode-* suites declare every
/// ID_Start/ID_Continue character — some versions run to 4800+ lines).
///
/// What it DOES still do:
///   - Mark has_lexical_bindings = true so the compiler does not elide the
///     class's PUSH_LEX. The lex env is needed at runtime: PUTLEX stores
///     each fresh NEW_PRIV_SYM there, and inner functions resolve the slot
///     by walking the env chain.
///   - Intern the name (via str_intern in the caller; intern_slot_name)
///     so its byte slice is stable for PrivateNameEntry to keep.
///
/// What it does NOT do:
///   - Allocate a register (the slot has no compile-time register identity
///     in the class-enclosing scope).
///   - Push to scope_stack (no scope_stack entry means reclaim_stmt_regs
///     and pop_scope_to can't accidentally try to free a register we never
///     owned; resolve_var / find_local_reg never see the slot because all
///     accesses go through GETVAR with a const-pool name anyway).
fn void CompilerContext.declare_priv_slot(&self, char[] name) {
    // Mark the enclosing scope as having lexical bindings — required so the
    // class's PUSH_LEX is emitted and the env elision gate (has_closures &&
    // has_lexical_bindings) keeps the env alive.
    self.has_lexical_bindings = true;
}

/// Push a fresh private-name scope for a class body about to be parsed.
fn void CompilerContext.push_private_scope(&self) {
    if (self.private_scope_depth < MAX_CLASS_NESTING) {
        self.private_scope_start[self.private_scope_depth] = self.private_name_count;
        self.private_class_id[self.private_scope_depth] = g_private_class_id++;
        self.private_scope_depth++;
    }
}

/// Pop the innermost private-name scope, discarding names declared inside it.
fn void CompilerContext.pop_private_scope(&self) {
    if (self.private_scope_depth > 0) {
        self.private_scope_depth--;
        self.private_name_count = self.private_scope_start[self.private_scope_depth];
    }
}

/// Declare a private name in the innermost (current) class scope.  Returns
/// a pointer to the new entry, or a fault on duplicate declaration (the
/// caller reports the SyntaxError) or table overflow.
///
/// Duplicate detection is scoped to the CURRENT class body only (names in
/// the same source span between the matching push/pop_private_scope calls);
/// an outer class's `#x` is legitimately shadowed by an inner class's own
/// `#x`, mirroring the spec's per-class PrivateEnvironment.
fn PrivateNameEntry*? CompilerContext.declare_private_name(&self, char[] name) {
    // INTERN FIRST. `str_intern` rewrites any raw 4-byte UTF-8 astral
    // sequences into CESU-8 surrogate pairs, so two byte forms that decode
    // to the same codepoint sequence (literal vs. \u{...} escape) end up
    // interned to the *same* HString. Equally important for our internal
    // bookkeeping: every entry's `.name` slot stores the interned slice,
    // so the duplicate-declaration loop below has to compare interned-vs-
    // interned (otherwise raw input with astral codepoints compares
    // against the longer CESU-8 form, fails str_eq's length check, and
    // either accepts a duplicate or, after the first successful insert,
    // makes a follow-up `resolve_private_name` miss the entry).
    char[] stable_name = self.intern_slot_name(name);
    uint scope_begin = self.private_scope_depth > 0
        ? self.private_scope_start[self.private_scope_depth - 1] : 0;
    for (uint i = scope_begin; i < self.private_name_count; i++) {
        if (str_eq(self.private_names[i].name, stable_name)) {
            return COMPILE_ERROR~;  // duplicate declaration
        }
    }
    self.ensure_private_name_cap();
    if (self.private_name_count >= self.private_name_cap) {
        return COMPILE_ERROR~;
    }
    uint idx = self.private_name_count;
    // NOTE: `stable_name` points at interned HString data — the source
    // `name` may itself point into the lexer's per-call ident_buf scratch
    // (for the slow HASH_IDENT path via scan_ident_body_decoded), which
    // gets overwritten on the next scan. Interning before storing fixes
    // the lifetime AND the form problem above. For raw UTF-8 names from
    // the fast path (source.slice), the slice was already stable, so
    // str_intern is essentially a no-op for them but harmless.
    self.private_names[idx].name = stable_name;
    self.private_names[idx].is_method = false;
    self.private_names[idx].has_getter = false;
    self.private_names[idx].has_setter = false;

    // Lexical binding name for the runtime symbol slot, e.g. "#priv:3:foo".
    // The '#' prefix is source-illegal as an identifier start (HASH_IDENT
    // tokens never include it), so user code can never collide with this
    // binding by name. Interned first: declare_priv_slot's lex-binding
    // tracker and the PrivateNameEntry both keep the slice, which must
    // outlive this frame.
    //
    // Note: we deliberately do NOT call declare_var here. The slot_name is
    // only ever accessed via GETVAR (env lookup by name) from __field_init__
    // and method bodies, never via direct register access in the class-
    // enclosing scope. Calling declare_var would allocate a register per
    // private name in the enclosing function's register file, exhausting the
    // 512-register limit for classes with ~500+ private fields (test262
    // start-unicode-*.js / part-unicode-*.js cover every ID_Start/ID_Continue
    // char from Unicode 5.2 through 17.0.0; some exceed 4500 entries).
    // declare_priv_slot marks the binding as lexical (so the class's lex
    // env isn't elided — PUTLEX still creates the binding at runtime) but
    // consumes no register and no scope_stack slot.
    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] slot_name_buf;
    char[] slot_name = self.intern_slot_name(
        format_private_slot_name(slot_name_buf[..], class_id, stable_name));

    self.declare_priv_slot(slot_name);
    self.private_names[idx].slot_name = slot_name;

    self.private_name_count++;
    return &self.private_names[idx];
}

/// Declare the class brand (one per class body that has any private member).
/// Uses a source-illegal name ("#priv:<id>:brand") distinct from any user
/// private name so it can never be resolved via `resolve_private_name`.
/// Returns the interned binding-name slice — callers add it to whichever
/// constant pool needs it (constant indices are context-relative).
///
/// Like declare_private_name's slot, this is bound via declare_priv_slot —
/// only GETVAR-accessed at runtime, never register-accessed by the class-
/// enclosing scope — so it must not consume a register (test262
/// start-unicode-*.js blow past the 512-register limit if it did).
fn char[] CompilerContext.declare_class_brand(&self) {
    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] brand_name_buf;
    char[] brand_name = self.intern_slot_name(
        format_private_slot_name(brand_name_buf[..], class_id, "brand"));
    self.declare_priv_slot(brand_name);
    return brand_name;
}

/// Declare the class's STATIC brand (P5) — a symbol distinct from the
/// instance brand, stamped on the constructor object rather than instances.
/// Uses a source-illegal name ("#priv:<id>:sbrand") so it can never be
/// resolved via `resolve_private_name`. Same register-free treatment as
/// declare_class_brand; see its comment for why.
fn char[] CompilerContext.declare_class_static_brand(&self) {
    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] sbrand_name_buf;
    char[] sbrand_name = self.intern_slot_name(
        format_private_slot_name(sbrand_name_buf[..], class_id, "sbrand"));
    self.declare_priv_slot(sbrand_name);
    return sbrand_name;
}

/// Return the interned HString* for a lexical binding name (e.g.
/// "#priv:brand" or a private name's own "#priv:foo" slot name), as a raw
/// void* independent of any particular CompilerContext's constant pool.
/// Used to stamp CompiledFunction.brand_name_hstr / resolve field-init
/// symbols at construction time, when the reading code (VM construct path)
/// has no access to the class-enclosing context's constants array.
fn void* CompilerContext.intern_private_binding_name(&self, char[] name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(name);
    return (void*)hstr;
}

/// Resolve a private name (without '#') to its declaring entry, searching
/// from the innermost enclosing class scope outward.  Returns a fault
/// (SyntaxError) if no enclosing class declares this name.
///
/// `name` is the raw token text as scanned from source (potentially with
/// 4-byte UTF-8 astral codepoints when a literal character or `\u{...}`
/// escape decoded to a supplementary-plane value). We re-intern it before
/// comparing against stored entries — every entry's `.name` was itself
/// interned by declare_private_name, and `str_intern` rewrites raw astral
/// UTF-8 to CESU-8 surrogate pairs, so byte-level comparison only works
/// if both sides go through the same canonicalisation.
fn PrivateNameEntry*? CompilerContext.resolve_private_name(&self, char[] name) {
    char[] canonical_name = self.intern_slot_name(name);
    uint i = self.private_name_count;
    while (i > 0) {
        i--;
        if (str_eq(self.private_names[i].name, canonical_name)) {
            return &self.private_names[i];
        }
    }
    return COMPILE_ERROR~;
}

/// Pre-scan a class body for private-name DECLARATIONS (Phase A, plan 054
/// §2a) and declare them all before any member body compiles, so that a
/// field initializer may forward-reference a `#name` declared later in the
/// same class.  The lexer must be positioned just BEFORE the class body's
/// opening `{`; on return the lexer state is fully restored (mirrors
/// pre_scan_captures / the for-loop LHS snapshot machinery).
///
/// Declarations recognised: `#name` at the class body's top nesting level,
/// immediately preceded by nothing, `static`, `get`, `set`, `async`, or `*`
/// (i.e. `#name` as a class-element key, not `this.#name` or `obj?.#name`
/// inside a method body, which never appear at brace-depth 0 relative to
/// the class body's own `{`).
///
/// Also classifies each declaration (P3/P4/P5): whether `static` precedes
/// it, whether it is immediately followed by `(` (a method), and whether it
/// is preceded by a bare `get`/`set` modifier token (an accessor). A
/// `get #x` + `set #x` pair for the same name merges into one entry; any
/// other re-declaration of the same name is a SyntaxError.
fn void? CompilerContext.prescan_private_names(&self) {
    uint saved_pos    = self.lexer.pos;
    uint saved_line    = self.lexer.line;
    uint saved_col      = self.lexer.col;
    Token saved_cur    = self.lexer.current;
    Token saved_look    = self.lexer.lookahead;
    bool  saved_haslk   = self.lexer.has_lookahead;
    Token saved_push    = self.lexer.pushed_back;
    bool  saved_haspb   = self.lexer.has_pushed_back;
    bool  saved_slt     = self.lexer.seen_line_term;

    // Expect the class body's opening brace.
    Token? open_opt = self.lexer.next_token();
    if (catch _e = open_opt) {
        self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
        return;
    }
    if (open_opt.type != TokenType.LBRACE) {
        self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
        return;
    }

    uint depth = 1;  // inside the class body's own braces
    uint template_depth = 0;  // open template substitution levels

    // Rolling state for the CURRENT class element, reset at every element
    // boundary (`;` at depth 1, or depth returning to 1 after a nested
    // `{`/`(`/`[`, i.e. after a previous element's body/computed-key/params
    // closed). `elem_saw_static` / `elem_get_set` describe modifiers seen
    // for THIS element so far; a HASH_IDENT at depth==1 consumes them.
    bool elem_saw_static = false;
    char elem_get_set = 0;  // 'g', 's', or 0 (none)
    TokenType prev_tok_type = TokenType.EOF_TOKEN;
    while (depth > 0) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _e2 = tok_opt) break;
        Token tok = tok_opt;
        if (tok.type == TokenType.EOF_TOKEN) break;

        if (tok.type == TokenType.TEMPLATE_HEAD) {
            // The lexer consumed `...${; expression tokens follow, then a
            // RBRACE that belongs to the template substitution, not a block.
            template_depth++;
        } else if (tok.type == TokenType.RBRACE && template_depth > 0) {
            Token? part_opt = self.lexer.scan_template_after_expr();
            if (catch _e3 = part_opt) break;
            if (part_opt.type != TokenType.TEMPLATE_MIDDLE) {
                template_depth--;
            }
        } else if (tok.type == TokenType.LBRACE) {
            depth++;
        } else if (tok.type == TokenType.RBRACE) {
            depth--;
            if (depth == 1) {
                // Closed a method body / computed-key function: element done.
                elem_saw_static = false;
                elem_get_set = 0;
            }
        } else if (depth == 1 && tok.type == TokenType.SEMICOLON) {
            // Empty class element / end of a field declaration.
            elem_saw_static = false;
            elem_get_set = 0;
        } else if (depth == 1 && tok.type == TokenType.STATIC) {
            elem_saw_static = true;
        } else if (depth == 1 && tok.type == TokenType.IDENTIFIER
                   && (str_eq(tok.str_value, "get") || str_eq(tok.str_value, "set"))) {
            // Only a modifier if NOT immediately followed by `(` or `=`/`;`
            // (i.e. `get` / `set` used as an ordinary member name). Peek
            // without consuming.
            Token? next_opt = self.lexer.peek();
            bool is_modifier = true;
            if (try nxt = next_opt) {
                if (nxt.type == TokenType.LPAREN || nxt.type == TokenType.ASSIGN
                    || nxt.type == TokenType.SEMICOLON) {
                    is_modifier = false;
                }
            }
            if (is_modifier) {
                elem_get_set = tok.str_value[0];
            } else {
                elem_saw_static = false;
                elem_get_set = 0;
            }
        } else if (depth == 1 && tok.type == TokenType.HASH_IDENT
                   && prev_tok_type != TokenType.DOT && prev_tok_type != TokenType.OPT_CHAIN) {
            // A HASH_IDENT at the class body's own nesting level is a
            // declaration UNLESS it's a `this.#x` / `obj?.#x` access — those
            // can appear directly at this depth too (field initializers and
            // default-parameter expressions are not wrapped in their own
            // `{`/`(`/`[`, so parens in `f=(()=>this.#s)` or `m(x=this.#p)`
            // don't push depth past 1). Only `.`/`?.` immediately precede a
            // private-name access; every declaration site starts an element.
            char[] name = tok.str_value;
            bool is_ctor_name = str_eq(name, "constructor");
            if (is_ctor_name) {
                // #constructor is a SyntaxError (spec: forbidden private name).
                self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
                return self.fail("#constructor is not allowed as a private name")~;
            }

            bool is_method_decl = false;
            Token? follow_opt = self.lexer.peek();
            if (try flw = follow_opt) {
                if (flw.type == TokenType.LPAREN) is_method_decl = true;
            }

            bool is_getter = elem_get_set == 'g';
            bool is_setter = elem_get_set == 's';
            bool is_static_decl = elem_saw_static;
            // Reset for the next element — a HASH_IDENT always starts a new
            // class element (method/accessor bodies/params follow as nested
            // depth, and field declarations end at the next `;`/RBRACE).
            elem_saw_static = false;
            elem_get_set = 0;

            if (is_getter || is_setter) {
                if (catch derr = self.declare_or_merge_private_accessor(name, is_getter, is_setter, is_static_decl)) {
                    self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
                    return self.fail("duplicate private name declaration")~;
                }
            } else {
                if (catch derr = self.declare_private_name(name)) {
                    self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
                    return self.fail("duplicate private name declaration")~;
                }
                PrivateNameEntry* e = self.resolve_private_name(name)!;
                e.is_method = is_method_decl;
                e.is_static = is_static_decl;
            }
        } else if (depth == 1 && tok.type != TokenType.STAR
                   && !(tok.type == TokenType.IDENTIFIER && str_eq(tok.str_value, "async"))) {
            // Any other token at depth 1 (identifiers, strings, numbers,
            // `[` computed-key openers not yet at depth 2, etc.) means we
            // are no longer at the start of an element's modifier prefix —
            // but `*`/`async` are themselves modifiers, so they don't reset.
            // Non-modifier tokens (e.g. a plain method/field name) DO belong
            // to the current element and must not clear static/get/set that
            // were already seen for it.
        }
        prev_tok_type = tok.type;
    }

    self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
}

/// Declare a private accessor name, or merge into an existing entry of the
/// same name IF the existing entry is itself an accessor (getter XOR
/// setter) and this declaration supplies the other half (`get #x` + `set
/// #x`). Any other re-use of the name (field, method, or a second getter/
/// setter of the same kind) is a duplicate-declaration error.
fn void? CompilerContext.declare_or_merge_private_accessor(&self, char[] name, bool is_getter, bool is_setter, bool is_static_decl) {
    uint scope_begin = self.private_scope_depth > 0
        ? self.private_scope_start[self.private_scope_depth - 1] : 0;
    for (uint i = scope_begin; i < self.private_name_count; i++) {
        if (str_eq(self.private_names[i].name, name)) {
            PrivateNameEntry* e = &self.private_names[i];
            bool mergeable = e.is_method
                && ((is_getter && e.has_getter == false && e.has_setter)
                    || (is_setter && e.has_setter == false && e.has_getter));
            if (!mergeable) return COMPILE_ERROR~;
            if (is_getter) e.has_getter = true;
            if (is_setter) e.has_setter = true;
            return;
        }
    }
    PrivateNameEntry* entry = self.declare_private_name(name)!;
    entry.is_method = true;
    entry.has_getter = is_getter;
    entry.has_setter = is_setter;
    entry.is_static = is_static_decl;
}

/// Restore lexer state captured before prescan_private_names ran.
fn void CompilerContext.restore_prescan_lexer(&self, uint pos, uint line, uint col,
        Token cur, Token look, bool haslk, Token push, bool haspb, bool slt) {
    self.lexer.pos             = pos;
    self.lexer.line            = line;
    self.lexer.col             = col;
    self.lexer.current         = cur;
    self.lexer.lookahead       = look;
    self.lexer.has_lookahead   = haslk;
    self.lexer.pushed_back     = push;
    self.lexer.has_pushed_back = haspb;
    self.lexer.seen_line_term  = slt;
}

/// Emit the shared prelude for a private-field access `obj.#name`: resolve
/// the name (SyntaxError if undeclared), CHK_BRAND `obj_reg` against the
/// OWNING CLASS's brand symbol (own-only presence check; TypeError at
/// runtime if absent — the brand, not this field's own key, is the
/// unforgeable per-class marker every field/method shares), then load this
/// name's own runtime symbol into a fresh register via GETVAR. Returns the
/// register holding the resolved field symbol — the caller emits
/// GETPROP/PUTPROP with it.
fn ushort? CompilerContext.emit_private_access(&self, char[] name, ushort obj_reg) {
    PrivateNameEntry* entry = self.resolve_private_name(name)!;
    // The binding-name constants go into THIS context's pool — entry only
    // carries the stable name text, never a pool index, because this runs
    // inside method/initializer bodies whose pools differ from the
    // class-enclosing context that declared the entry.
    uint brand_bind_idx = self.add_string_constant(entry.brand_slot_name);
    ushort brand_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)brand_reg, brand_bind_idx));
    uint name_const_idx = self.add_string_constant(name);
    uint name_c = name_const_idx <= 0xFE ? name_const_idx : 0xFF;
    self.emit_abc(Opcode.CHK_BRAND, (uint)obj_reg, (uint)brand_reg, name_c);
    self.free_reg(brand_reg);

    ushort key_reg = self.alloc_reg();
    uint slot_bind_idx = self.add_string_constant(entry.slot_name);
    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg, slot_bind_idx));
    return key_reg;
}
