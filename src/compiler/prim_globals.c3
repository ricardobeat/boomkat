module duktape::compiler;

import duktape::lexer;
import std::io;

// ============================================================================
// Whole-program primitive-only global proof (GETGLOBAL_PRIM / PUTGLOBAL_PRIM)
// ============================================================================
//
// A top-level `var`/`function` global is PRIMITIVE-ONLY iff EVERY assignment to
// its name anywhere in the compilation unit (including nested function bodies)
// stores a provably-primitive value, AND the unit has no eval/globalThis/window/
// Function/with/global-`this` observability that could inject a heap value from
// outside the compiler's view. Reads/writes of such a global then compile to the
// guard-free GETGLOBAL_PRIM / PUTGLOBAL_PRIM opcodes (no is_heap check, no
// refcount, no track_heap_store).
//
// SOUNDNESS: the whole correctness argument is
//   (1) the observability gate — if ANY of the escape hatches appears, NO global
//       is treated primitive-only (the entire set is discarded); and
//   (2) clearing the primitive-only bit on ANY assignment whose right-hand side
//       is not provably primitive, including assignments inside nested functions
//       and assignments whose RHS names a non-primitive-only global (resolved to
//       a fixpoint). Strings and bigints are HEAP in this engine, so a string /
//       template / bigint literal RHS clears the bit.
//
// The scan is deliberately CONSERVATIVE: whenever it cannot prove primitiveness
// (unknown identifier RHS, member/call/new RHS, capacity overflow, or any
// observability hazard) it falls back to the guarded GETGLOBAL/PUTGLOBAL path.
// A false negative only costs the optimization; a false positive would be a
// refcount UAF/leak, so every ambiguous case resolves to "not primitive-only".

const uint PRIM_MAX_CANDIDATES = 256;
const uint PRIM_MAX_DEPS = 8;       // per-candidate RHS-identifier dependencies

struct PrimCandidate {
    char[64] name;
    ushort   name_len;
    bool     prim_only;             // still provably primitive-only?
    bool     declared;              // top-level var/function name (emit target)
    // Names this candidate's RHS depends on (an RHS bare identifier that is
    // itself a candidate). If any dep is not primitive-only, this clears too.
    char[64][PRIM_MAX_DEPS] deps;
    ushort[PRIM_MAX_DEPS]    dep_lens;
    uint                     dep_count;
    bool dep_overflow;              // more deps than PRIM_MAX_DEPS -> not prim
}

// Reserved identifier names that denote a primitive value even though the lexer
// tokenizes them as IDENTIFIER (this engine has no dedicated true/false/null
// tokens). Any other bare identifier in an RHS is treated as a dependency.
fn bool is_primitive_ident_name(char[] name) {
    switch (name.len) {
        case 4:
            if (name == "true") return true;
            if (name == "null") return true;
            return false;
        case 5:
            if (name == "false") return true;
            return false;
        case 3:
            if (name == "NaN") return true;
            return false;
        case 8:
            if (name == "Infinity") return true;
            return false;
        case 9:
            if (name == "undefined") return true;
            return false;
        default:
            return false;
    }
}

// A bare identifier that, if it appears anywhere in the unit, forces the whole
// primitive-only analysis off (observability escape hatch).
fn bool is_prim_observability_name(char[] name) {
    switch (name.len) {
        case 4:
            return name == "eval";
        case 6:
            return name == "window";
        case 8:
            return name == "Function";
        case 10:
            return name == "globalThis";
        default:
            return false;
    }
}

// Classifier verdict for the token following the current RHS position.
fn PrimCandidate* prim_find(PrimCandidate* table, uint count, char[] name) {
    for (uint i = 0; i < count; i++) {
        if (table[i].name_len == name.len) {
            bool same = true;
            for (usz j = 0; j < name.len; j++) {
                if (table[i].name[j] != name[j]) { same = false; break; }
            }
            if (same) return &table[i];
        }
    }
    return null;
}

fn PrimCandidate* prim_intern(PrimCandidate* table, uint* count, char[] name, bool* overflow) {
    if (name.len == 0 || name.len > 63) { *overflow = true; return null; }
    PrimCandidate* existing = prim_find(table, *count, name);
    if (existing != null) return existing;
    if (*count >= PRIM_MAX_CANDIDATES) { *overflow = true; return null; }
    PrimCandidate* c = &table[*count];
    for (usz j = 0; j < name.len; j++) c.name[j] = name[j];
    c.name_len = (ushort)name.len;
    c.prim_only = true;
    c.declared = false;
    c.dep_count = 0;
    c.dep_overflow = false;
    (*count)++;
    return c;
}

/// Whole-program pre-scan (Script global scope only). Populates
/// self.prim_only_name_idxs with the constant-pool indices of proven
/// primitive-only top-level globals. Lexer state is fully saved and restored.
fn void CompilerContext.pre_scan_prim_globals(&self) {
    // Only Script global scope: modules bind via GETVAR (no GETGLOBAL), and the
    // opcodes are only substituted at global slot scope anyway.
    if (!self.is_global || self.is_module) return;

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

    PrimCandidate[] table_sl = mem::temp_array(PrimCandidate, PRIM_MAX_CANDIDATES);
    PrimCandidate* table = table_sl.ptr;
    uint count = 0;
    bool overflow = false;
    bool disabled = false;   // observability hazard -> discard everything

    // Token-walk state.
    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[64] prev_ident;         // str_value of the previous IDENTIFIER (if prev_tt==IDENTIFIER)
    ushort   prev_ident_len = 0;
    bool decl_context = false;   // inside a `var`/`let`/`const` declarator list at global scope
    bool decl_is_var = false;    // the active declarator list is `var` (no TDZ)
    int  decl_paren = 0;         // paren depth when the declarator list began
    int  decl_bracket = 0;       // bracket depth when the declarator list began
    int  decl_brace = 0;         // brace depth when the declarator list began
    uint paren_depth = 0;
    uint bracket_depth = 0;
    uint brace_depth = 0;

    // RHS scanning state: when set, we are consuming the right-hand side of an
    // assignment/initializer for `rhs_target`, tracking whether it stays prim.
    PrimCandidate* rhs_target = null;
    bool rhs_is_prim = true;
    int  rhs_start_paren = 0;
    int  rhs_start_bracket = 0;
    int  rhs_start_brace = 0;

    // for-header tracking: a `for (` header may be a for-of / for-in whose loop
    // variable is bound to (heap) iteration values. When the header contains
    // `of` / `in`, the loop variable is NOT primitive-only.
    bool in_for_header = false;
    int  for_header_paren = 0;   // paren_depth at the `(` after `for`
    bool for_saw_of_in = false;  // header contains `of` or `in` (binding form)

    // Destructuring LHS tracking: an assignment/binding whose target is a `[`/`{`
    // pattern binds names to (heap/unknown) values. Any candidate name appearing
    // inside such a pattern is NOT primitive-only. We conservatively clear every
    // candidate identifier seen inside a pattern that is later closed by `] =` /
    // `} =` or that follows `var`/`let`/`const [`/`{`.
    bool in_destructure = false;
    int  destructure_paren = 0;
    int  destructure_bracket = 0;
    int  destructure_brace = 0;

    while (!disabled) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        Token tok = tok_opt;
        TokenType tt = tok.type;
        if (tt == TokenType.EOF_TOKEN) break;

        // --- Observability hazards: any occurrence disables the whole proof ---
        // `with` and any `eval`/`globalThis`/`window`/`Function` reference can
        // read/assign a global by name out of view. `this` at global scope is
        // globalThis (so `this.foo = obj` could inject a heap value into global
        // `foo`); distinguishing global-scope `this` from a method receiver at
        // token level is not reliable, so ANY `this` disables the proof. These
        // benches use no `this`, so the conservatism costs nothing here.
        if (tt == TokenType.WITH) { disabled = true; break; }
        if (tt == TokenType.THIS) { disabled = true; break; }
        if (tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            if (is_prim_observability_name(nm)) { disabled = true; break; }
        }

        // --- Close an active RHS scan when the assignment expression ends ---
        if (rhs_target != null) {
            bool ends = false;
            if ((tt == TokenType.SEMICOLON || tt == TokenType.COMMA)
                && (int)paren_depth <= rhs_start_paren
                && (int)bracket_depth <= rhs_start_bracket
                && (int)brace_depth <= rhs_start_brace) {
                ends = true;
            } else if (tt == TokenType.RPAREN && (int)paren_depth <= rhs_start_paren) {
                ends = true;
            } else if (tt == TokenType.RBRACKET && (int)bracket_depth <= rhs_start_bracket) {
                ends = true;
            } else if (tt == TokenType.RBRACE && (int)brace_depth <= rhs_start_brace) {
                ends = true;
            }
            if (ends) {
                if (!rhs_is_prim) rhs_target.prim_only = false;
                rhs_target = null;
            } else {
                // Accumulate the RHS token's effect on primitiveness.
                self.prim_rhs_token(tok, tt, prev_tt, rhs_target, &rhs_is_prim, table, count);
            }
        }

        // --- Structural depth bookkeeping ---
        switch (tt) {
            case TokenType.LPAREN:   paren_depth++;
            case TokenType.RPAREN:   if (paren_depth > 0) paren_depth--;
            case TokenType.LBRACKET: bracket_depth++;
            case TokenType.RBRACKET: if (bracket_depth > 0) bracket_depth--;
            case TokenType.LBRACE:   brace_depth++;
            case TokenType.RBRACE:   if (brace_depth > 0) brace_depth--;
            default: break;
        }

        // --- for-header tracking (detect for-of / for-in binding forms) ---
        if (prev_tt == TokenType.FOR && tt == TokenType.LPAREN) {
            in_for_header = true;
            for_header_paren = (int)paren_depth;   // depth AFTER consuming `(`
            for_saw_of_in = false;
        }
        if (in_for_header) {
            // `of` (contextual) or `in` at header depth marks the binding form;
            // the loop variable(s) receive heap/unknown iteration values.
            bool is_of = (tt == TokenType.IDENTIFIER && tok.str_value == "of");
            if ((tt == TokenType.IN || is_of) && (int)paren_depth == for_header_paren) {
                for_saw_of_in = true;
                // Clear every candidate identifier seen in the header so far.
                // (The loop variable list precedes `of`/`in`.)
            }
            if (tt == TokenType.RPAREN && (int)paren_depth < for_header_paren) {
                in_for_header = false;
            }
        }

        // --- Declaration context: `var`/`let`/`const` at global scope ---
        // Only `var` (and `function`) globals are eligible to be treated
        // primitive-only: they are hoist-initialized to undefined (no TDZ), so a
        // guard-free read before assignment is safe. `let`/`const` have a TDZ
        // whose read must THROW, which the guard-free opcodes do not do — those
        // are never marked declared (they keep the guarded GETGLOBAL path).
        if (tt == TokenType.VAR || tt == TokenType.LET || tt == TokenType.CONST) {
            decl_context = true;
            decl_is_var = (tt == TokenType.VAR);
            decl_paren = (int)paren_depth;
            decl_bracket = (int)bracket_depth;
            decl_brace = (int)brace_depth;
        }

        // --- Destructuring pattern detection ---
        // A `[` or `{` after `var`/`let`/`const`, or at the start of an
        // expression-statement assignment, opens a binding pattern whose names
        // are bound to heap/unknown values. Enter destructure mode; clear any
        // candidate identifier seen until the pattern closes.
        // A `[`/`{` in any position where a destructuring TARGET can appear:
        // after `var`/`let`/`const`, in a for-binding, at statement start, or
        // after `=` / `(` / `,` (e.g. `a = [x, ...y] = vals`, `([a] = o)`). This
        // deliberately also catches array/object LITERALS used as an RHS in
        // those positions; clearing the candidate identifiers they contain is
        // over-conservative but sound (a false negative only forgoes the
        // optimization, never a refcount hazard).
        if (!in_destructure && (tt == TokenType.LBRACKET || tt == TokenType.LBRACE)) {
            bool after_decl = (prev_tt == TokenType.VAR || prev_tt == TokenType.LET
                               || prev_tt == TokenType.CONST);
            bool stmt_start = (prev_tt == TokenType.SEMICOLON || prev_tt == TokenType.LBRACE
                               || prev_tt == TokenType.RBRACE || prev_tt == TokenType.EOF_TOKEN);
            bool after_assign_ctx = (prev_tt == TokenType.ASSIGN || prev_tt == TokenType.LPAREN
                               || prev_tt == TokenType.COMMA);
            bool in_for_bind = in_for_header;
            if (after_decl || in_for_bind || stmt_start || after_assign_ctx) {
                in_destructure = true;
                destructure_paren = (int)paren_depth;
                destructure_bracket = (int)bracket_depth;
                destructure_brace = (int)brace_depth;
            }
        }
        if (in_destructure) {
            if (tt == TokenType.IDENTIFIER) {
                char[] nm = tok.str_value;
                PrimCandidate* dc = prim_find(table, count, nm);
                if (dc != null) {
                    dc.prim_only = false;
                } else {
                    // A pattern binding to a not-yet-seen name: intern + clear so
                    // a later fixpoint dep on it fails.
                    PrimCandidate* nc = prim_intern(table, &count, nm, &overflow);
                    if (overflow) { disabled = true; break; }
                    if (nc != null) nc.prim_only = false;
                }
            }
            // Close the pattern once depths return to/below the entry level and
            // we hit `=`, `;`, `)` or `of`/`in`.
            bool close_pat = false;
            if ((int)bracket_depth <= destructure_bracket && (int)brace_depth <= destructure_brace) {
                if (tt == TokenType.ASSIGN || tt == TokenType.SEMICOLON
                    || tt == TokenType.RPAREN || tt == TokenType.IN
                    || (tt == TokenType.IDENTIFIER && tok.str_value == "of")) {
                    close_pat = true;
                }
            }
            if (close_pat) in_destructure = false;
        }

        // --- for-of / for-in loop variable clearing ---
        // When the header binding form is confirmed, clear the loop variable(s).
        // The variable is the identifier(s) between `(` [optional var/let/const]
        // and `of`/`in`. We clear the identifier immediately preceding `of`/`in`.
        if (in_for_header && for_saw_of_in) {
            if (prev_tt == TokenType.IDENTIFIER && prev_ident_len > 0) {
                char[] lv = prev_ident[:prev_ident_len];
                PrimCandidate* lc = prim_find(table, count, lv);
                if (lc == null) {
                    lc = prim_intern(table, &count, lv, &overflow);
                    if (overflow) { disabled = true; break; }
                }
                if (lc != null) lc.prim_only = false;
            }
            for_saw_of_in = false;  // clear once; header consumed
        }

        // --- Detect an assignment / initializer target ---
        // Pattern: previous token was an IDENTIFIER and current is `=` (simple
        // assignment) or a compound-assign / ++ / --. The identifier is the LHS.
        if (prev_tt == TokenType.IDENTIFIER && prev_ident_len > 0) {
            char[] lhs = prev_ident[:prev_ident_len];
            bool is_simple_assign = (tt == TokenType.ASSIGN);
            bool is_compound_numeric = prim_is_numeric_compound(tt);
            bool is_compound_plus = (tt == TokenType.PLUS_ASSIGN);
            bool is_logical_assign = (tt == TokenType.LOG_AND_ASSIGN
                || tt == TokenType.LOG_OR_ASSIGN || tt == TokenType.NULLISH_ASSIGN);

            if (is_simple_assign || is_compound_numeric || is_compound_plus || is_logical_assign) {
                // A nested assignment inside an already-open RHS (`a = (b = ...)`)
                // means the outer target's value flows from an assignment
                // expression whose result we can no longer track — conservatively
                // clear the outer target.
                if (rhs_target != null) rhs_target.prim_only = false;

                PrimCandidate* c = prim_intern(table, &count, lhs, &overflow);
                if (overflow) { disabled = true; break; }
                if (c != null) {
                    // A numeric compound (-=, *=, ...) always yields a number, so
                    // the target stays primitive regardless of the RHS: no RHS
                    // scan needed. Simple `=`, `+=`, and logical-assigns flow the
                    // RHS value into the binding -> the RHS must be provably prim.
                    if (is_compound_numeric) {
                        rhs_target = null;   // result is always numeric-primitive
                    } else {
                        rhs_target = c;
                        rhs_is_prim = true;
                        rhs_start_paren = (int)paren_depth;
                        rhs_start_bracket = (int)bracket_depth;
                        rhs_start_brace = (int)brace_depth;
                    }
                } else {
                    rhs_target = null;
                }
            }
        }

        // --- Declared var names ---
        // `var NAME` introduces a binding with no TDZ. Mark it declared (an
        // eligible PRIM emit target). Detecting a `var` inside a nested function
        // (a local, not a global) is harmless: it only ever matters combined
        // with a global-scope GETGLOBAL read of the same name, and any local or
        // nested assignment to it is scanned and would clear its bit. `let`/
        // `const` are intentionally excluded (TDZ). A `function NAME` binds NAME
        // to a closure (heap) -> NOT primitive-only.
        // A declarator continues after a comma only at the SAME nesting depth as
        // the `var` keyword — a comma inside the initializer's `f(a, b)` / `[..]`
        // / `{..}` is not a new declarator (it separates call args / elements).
        bool at_decl_depth = ((int)paren_depth == decl_paren
                              && (int)bracket_depth == decl_bracket
                              && (int)brace_depth == decl_brace);
        // Only a `var` at top-level brace depth (0) declares a GLOBAL binding;
        // a `var` inside any function body sits at brace_depth >= 1 (all function
        // bodies are `{}`-delimited) and is a LOCAL. Gating `declared` on
        // brace_depth == 0 keeps the emitted PRIM set to real globals and avoids
        // polluting the top-level constant pool with function-local names.
        if (brace_depth == 0
            && (prev_tt == TokenType.VAR
                || (decl_context && decl_is_var && at_decl_depth && prev_tt == TokenType.COMMA))
            && tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            PrimCandidate* c = prim_intern(table, &count, nm, &overflow);
            if (overflow) { disabled = true; break; }
            if (c != null) c.declared = true;
        }
        if (prev_tt == TokenType.FUNCTION && tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            PrimCandidate* c = prim_intern(table, &count, nm, &overflow);
            if (overflow) { disabled = true; break; }
            if (c != null) c.prim_only = false;
        }
        // Reset declaration context at statement end.
        if (tt == TokenType.SEMICOLON && paren_depth == 0) decl_context = false;

        // --- Track previous identifier for LHS detection ---
        if (tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            if (nm.len <= 63) {
                for (usz j = 0; j < nm.len; j++) prev_ident[j] = nm[j];
                prev_ident_len = (ushort)nm.len;
            } else {
                prev_ident_len = 0;
            }
        } else {
            prev_ident_len = 0;
        }
        prev_tt = tt;
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.seen_line_term  = saved_slt;

    if (disabled || overflow || count == 0) return;

    // --- Fixpoint: clear prim_only for any candidate whose dependency set
    //     references a non-candidate or non-primitive-only name. Iterate until
    //     stable (monotone clearing terminates in <= count passes). ---
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint i = 0; i < count; i++) {
            if (!table[i].prim_only) continue;
            if (table[i].dep_overflow) { table[i].prim_only = false; changed = true; continue; }
            for (uint d = 0; d < table[i].dep_count; d++) {
                char[] dn = table[i].deps[d][:table[i].dep_lens[d]];
                if (is_primitive_ident_name(dn)) continue;
                PrimCandidate* dep = prim_find(table, count, dn);
                if (dep == null || !dep.prim_only) {
                    table[i].prim_only = false;
                    changed = true;
                    break;
                }
            }
        }
    }

    // --- Emit the proven set: declared global AND primitive-only. Intern each
    //     name to its canonical constant-pool index (matching emit-time
    //     add_string_constant) and record it. ---
    for (uint i = 0; i < count; i++) {
        if (table[i].declared && table[i].prim_only) {
            uint idx = self.add_string_constant(table[i].name[:table[i].name_len]);
            if (!self.prim_only_name_idxs.contains(idx)) {
                self.prim_only_name_idxs.push(idx);
            }
        }
    }
}

// A compound-assign whose result is always a number/bigint (never a string):
// everything except `+=` and the logical-assigns.
fn bool prim_is_numeric_compound(TokenType tt) {
    switch (tt) {
        case TokenType.MINUS_ASSIGN:
        case TokenType.STAR_ASSIGN:
        case TokenType.SLASH_ASSIGN:
        case TokenType.PERCENT_ASSIGN:
        case TokenType.STARSTAR_ASSIGN:
        case TokenType.SHL_ASSIGN:
        case TokenType.SHR_ASSIGN:
        case TokenType.USHR_ASSIGN:
        case TokenType.BIT_AND_ASSIGN:
        case TokenType.BIT_OR_ASSIGN:
        case TokenType.BIT_XOR_ASSIGN:
            return true;
        default:
            return false;
    }
}

// Fold one RHS token into the running primitiveness verdict for the current
// assignment target. `rhs_is_prim` starts true and is cleared on any heap-
// producing construct; primitive-only dependencies are recorded on the target.
fn void CompilerContext.prim_rhs_token(&self, Token tok, TokenType tt, TokenType prev_tt,
                                       PrimCandidate* target, bool* rhs_is_prim,
                                       PrimCandidate* table, uint count) {
    if (!*rhs_is_prim) return;   // already heap; nothing more to learn
    switch (tt) {
        // Heap literals / heap-producing constructs.
        case TokenType.STRING:
        case TokenType.TEMPLATE:
        case TokenType.TEMPLATE_HEAD:
        case TokenType.TEMPLATE_MIDDLE:
        case TokenType.TEMPLATE_TAIL:
        case TokenType.REGEXP:
        case TokenType.BIGINT:
        case TokenType.LBRACE:      // object literal
        case TokenType.LBRACKET:    // array literal OR member index -> heap either way
        case TokenType.FUNCTION:
        case TokenType.ARROW:
        case TokenType.CLASS:
        case TokenType.NEW:
        case TokenType.DOT:         // property read -> possibly heap
        case TokenType.SUPER:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            *rhs_is_prim = false;
            target.prim_only = false;   // clear NOW (survives rhs_target clobber)
            return;
        case TokenType.LPAREN:
            // A call if directly applied to a value: prev token is an
            // identifier / `)` / `]`. Grouping `(...)` after an operator is fine.
            if (prev_tt == TokenType.IDENTIFIER || prev_tt == TokenType.RPAREN
                || prev_tt == TokenType.RBRACKET) {
                *rhs_is_prim = false;
                target.prim_only = false;
            }
            return;
        case TokenType.IDENTIFIER:
            char[] nm = tok.str_value;
            if (is_primitive_ident_name(nm)) return;   // true/false/null/undefined/NaN/Infinity
            // A bare identifier RHS: primitive only if it is itself a
            // primitive-only candidate global. Record as a dependency (resolved
            // to a fixpoint). Unknown identifiers (params, builtins, imports)
            // will not be found as candidates -> clears the target.
            if (target.dep_count < PRIM_MAX_DEPS) {
                if (nm.len <= 63) {
                    for (usz j = 0; j < nm.len; j++) target.deps[target.dep_count][j] = nm[j];
                    target.dep_lens[target.dep_count] = (ushort)nm.len;
                    target.dep_count++;
                } else {
                    *rhs_is_prim = false;
                    target.prim_only = false;
                }
            } else {
                target.dep_overflow = true;
            }
            return;
        default:
            // Numbers, operators (+ - * / typeof void ! comparisons logical),
            // parentheses grouping, etc. are all primitive-preserving.
            return;
    }
}

/// True when the given constant-pool name index was proven primitive-only.
fn bool CompilerContext.is_prim_only_global(&self, uint name_idx) {
    if (self.prim_only_name_idxs.len() == 0) return false;
    return self.prim_only_name_idxs.contains(name_idx);
}
