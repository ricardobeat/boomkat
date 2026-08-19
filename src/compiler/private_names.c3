module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;


// ============================================================================
// Private class members (ES2022), name resolution
//
// Each private name (`#foo`) declared in a class body gets a compiler-managed
// lexical variable in the scope enclosing the class, holding the per-evaluation
// runtime hidden symbol.
// ============================================================================

// The class id for private-slot binding names lives on the heap, one monotonic
// counter per runtime. All contexts in a runtime share it, so sibling classes
// compiled across the parent/arrow nested-context split get distinct ids, while
// separate runtimes never share it, so concurrent compiles on separate threads
// do not race. The id only keeps compile-time bindings distinct; per-evaluation
// freshness of the symbols comes from NEW_PRIV_SYM at runtime.

// Build the lexical binding name for a private slot into buf: "#priv:<id>:<name>".
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

// Intern a slot binding name and return its pinned byte slice.
// Pinned because the string table holds only weak references, so names that are
// not referenced elsewhere in the source would otherwise be reclaimed immediately.
fn char[] CompilerContext.intern_slot_name(&self, char[] slot_name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(slot_name);
    ((HeapHeader*)hstr).set_pinned();
    char[] data = hstr.get_data();
    return data;
}

// Register a private-name slot binding in the enclosing context without
// allocating a register or pushing to scope_stack.
//
// Accesses go through GETVAR by name from field initializers and method bodies,
// never by register in the class-enclosing scope. Omitting register allocation
// avoids exhausting the 512-register limit on classes with many private fields.
fn void CompilerContext.declare_priv_slot(&self, char[] name) {
    // Keeps the class's PUSH_LEX from being elided: the env-elision gate needs
    // this flag set for PUTLEX to store the fresh NEW_PRIV_SYM.
    self.has_lexical_bindings = true;
}

// Push a fresh private-name scope for a class body about to be parsed.
fn void CompilerContext.push_private_scope(&self) {
    if (self.private_scope_depth < MAX_CLASS_NESTING) {
        self.private_scope_start[self.private_scope_depth] = self.private_name_table.count;
        Heap* hp = (Heap*)self.heap;
        self.private_class_id[self.private_scope_depth] = hp.priv_class_id++;
        self.private_scope_depth++;
    }
}

// Pop the innermost private-name scope, discarding names declared inside it.
fn void CompilerContext.pop_private_scope(&self) {
    if (self.private_scope_depth > 0) {
        self.private_scope_depth--;
        self.private_name_table.count = self.private_scope_start[self.private_scope_depth];
    }
}

// Declare a private name in the innermost class scope.
// Interns the name first so raw UTF-8 astral characters and \u{...} escapes
// normalize to canonical CESU-8 before duplicate checks.
fn PrivateNameEntry*? CompilerContext.declare_private_name(&self, char[] name) {
    char[] stable_name = self.intern_slot_name(name);
    PrivateNameTable* t = self.private_name_table;
    uint scope_begin = self.private_scope_depth > 0
        ? self.private_scope_start[self.private_scope_depth - 1] : 0;
    for (uint i = scope_begin; i < t.count; i++) {
        if (str_eq(t.entries[i].name, stable_name)) {
            return COMPILE_ERROR~;  // duplicate declaration
        }
    }
    self.ensure_private_name_cap();
    if (t.count >= t.cap) {
        return COMPILE_ERROR~;
    }
    uint idx = t.count;
    t.entries[idx].name = stable_name;
    t.entries[idx].is_method = false;
    t.entries[idx].has_getter = false;
    t.entries[idx].has_setter = false;

    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] slot_name_buf;
    char[] slot_name = self.intern_slot_name(
        format_private_slot_name(slot_name_buf[..], class_id, stable_name));

    self.declare_priv_slot(slot_name);
    t.entries[idx].slot_name = slot_name;

    t.count++;
    return &t.entries[idx];
}

// Declare the class brand (one per class body with private members).
fn char[] CompilerContext.declare_class_brand(&self) {
    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] brand_name_buf;
    char[] brand_name = self.intern_slot_name(
        format_private_slot_name(brand_name_buf[..], class_id, "brand"));
    self.declare_priv_slot(brand_name);
    return brand_name;
}

// Declare the static class brand stamped on the constructor.
fn char[] CompilerContext.declare_class_static_brand(&self) {
    uint class_id = self.private_scope_depth > 0
        ? self.private_class_id[self.private_scope_depth - 1] : 0;
    char[96] sbrand_name_buf;
    char[] sbrand_name = self.intern_slot_name(
        format_private_slot_name(sbrand_name_buf[..], class_id, "sbrand"));
    self.declare_priv_slot(sbrand_name);
    return sbrand_name;
}

// Return the interned HString* for a lexical binding name, as a raw pointer
// independent of any context's constant pool. The VM construct path reads these
// back with no access to the class-enclosing context's constants array.
fn void* CompilerContext.intern_private_binding_name(&self, char[] name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(name);
    return (void*)hstr;
}

// Resolve a private name (without '#') to its declaring entry.
fn PrivateNameEntry*? CompilerContext.resolve_private_name(&self, char[] name) {
    char[] canonical_name = self.intern_slot_name(name);
    PrivateNameTable* t = self.private_name_table;
    uint i = t.count;
    while (i > 0) {
        i--;
        if (str_eq(t.entries[i].name, canonical_name)) {
            return &t.entries[i];
        }
    }
    char[128] buf;
    usz n = (usz)(io::bprintf(&buf, "private name '#%s' is not declared", (String)name) ?? buf[:0]).len;
    self.record_error(buf[:n]);
    return COMPILE_ERROR~;
}

// Pre-scan a class body for private-name declarations before any member body
// compiles, so a field initializer can forward-reference a #name declared later
// in the same class.
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
    TemplateScan tscan;

    // Rolling state for the current class element.
    bool elem_saw_static = false;
    char elem_get_set = 0;  // 'g', 's', or 0 (none)
    TokenType prev_tok_type = TokenType.EOF_TOKEN;
    while (depth > 0) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _e2 = tok_opt) break;
        Token tok = tok_opt;
        if (tok.type == TokenType.EOF_TOKEN) break;

        if (tok.type == TokenType.TEMPLATE_HEAD) {
            tscan.on_template_head();
        } else if (tok.type == TokenType.LBRACE) {
            tscan.on_lbrace();
            depth++;
        } else if (tok.type == TokenType.RBRACE) {
            TemplateBrace tb = tscan.classify_rbrace(self.lexer);
            if (tb == TemplateBrace.LEX_ERROR) break;
            if (tb == TemplateBrace.BLOCK) {
                depth--;
                if (depth == 1) {
                    elem_saw_static = false;
                    elem_get_set = 0;
                }
            }
        } else if (depth == 1 && tok.type == TokenType.SEMICOLON) {
            elem_saw_static = false;
            elem_get_set = 0;
        } else if (depth == 1 && tok.type == TokenType.STATIC) {
            elem_saw_static = true;
        } else if (depth == 1 && tok.type == TokenType.IDENTIFIER
                   && (str_eq(tok.str_value, "get") || str_eq(tok.str_value, "set"))) {
            // `get`/`set` is a modifier only when not used as an ordinary member
            // name, so peek: a following `(`, `=`, or `;` means it is a plain name.
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
            // A HASH_IDENT at the class body's own depth is a declaration unless
            // it is a this.#x / obj?.#x access; only `.` and `?.` precede those.
            char[] name = tok.str_value;
            bool is_ctor_name = str_eq(name, "constructor");
            if (is_ctor_name) {
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
            // Any other token at depth 1 ends the element's modifier prefix, but
            // `*` and `async` are themselves modifiers and must not clear
            // static/get/set already seen for this element.
        }
        prev_tok_type = tok.type;
    }

    self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
}

// Declare a private accessor name, or merge into an existing accessor entry of
// the same name. ES2022 requires the getter and setter halves to agree on
// static-ness: `get #f(){}` plus `static set #f(v){}` is a SyntaxError, not a
// mergeable pair.
fn void? CompilerContext.declare_or_merge_private_accessor(&self, char[] name, bool is_getter, bool is_setter, bool is_static_decl) {
    PrivateNameTable* t = self.private_name_table;
    uint scope_begin = self.private_scope_depth > 0
        ? self.private_scope_start[self.private_scope_depth - 1] : 0;
    for (uint i = scope_begin; i < t.count; i++) {
        if (str_eq(t.entries[i].name, name)) {
            PrivateNameEntry* e = &t.entries[i];
            bool mergeable = e.is_method
                && e.is_static == is_static_decl
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

// Restore lexer state captured before prescan_private_names ran.
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

// Emit the shared prelude for a private-field access obj.#name: resolve the
// name, load its brand symbol, and return the register holding the field's own
// runtime symbol.
//
// Deferred targets pre-allocate the brand register below the GETPROP result
// register; a lazily alloc_reg()'d register could land at or above it and be
// clobbered when the source property's getter runs (invoke_getter writes
// callee/this at [result_reg, result_reg + 1]). When defer_brand_check is set
// the CHK_BRAND is skipped and the caller emits it later, then frees brand_reg.
fn ushort? CompilerContext.emit_private_access(&self, char[] name, ushort obj_reg) {
    PrivateNameEntry* entry = self.resolve_private_name(name)!;
    uint brand_bind_idx = self.add_string_constant(entry.brand_slot_name);
    ushort brand_reg = self.deferred_brand_reg_hint != 0xFFFF
        ? self.deferred_brand_reg_hint : self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)brand_reg, brand_bind_idx);
    uint name_const_idx = self.add_string_constant(name);
    uint name_c = name_const_idx <= 0xFE ? name_const_idx : 0xFF;
    if (self.defer_brand_check) {
        self.deferred_brand_reg = brand_reg;
        self.deferred_brand_name_c = name_c;
        self.deferred_brand_obj_reg = obj_reg;
    } else {
        self.emit_abc(Opcode.CHK_BRAND, (uint)obj_reg, (uint)brand_reg, name_c);
        self.free_reg(brand_reg);
    }

    ushort key_reg = self.alloc_reg();
    uint slot_bind_idx = self.add_string_constant(entry.slot_name);
    self.emit_a_bc(Opcode.GETVAR, (uint)key_reg, slot_bind_idx);
    return key_reg;
}
