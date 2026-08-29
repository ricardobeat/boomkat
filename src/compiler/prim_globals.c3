module boomkat::compiler;

import boomkat::lexer;
import std::io;

// Whole-program primitive-only global proof (GETGLOBAL_PRIM / PUTGLOBAL_PRIM).
//
// A top-level `var`/`function` global is primitive-only if every assignment to
// its name anywhere in the compilation unit (including nested function bodies)
// stores a provably primitive value, and the unit contains no eval, globalThis,
// window, Function, with, or global-`this` references that could inject a heap
// value from outside the compiler's view. Reads and writes of these globals
// compile to GETGLOBAL_PRIM and PUTGLOBAL_PRIM without heap checks, refcounting,
// or heap-store tracking.
//
// Soundness rests on:
// 1. The observability gate: if any escape hatch appears, no global is treated
//    as primitive-only and the entire candidate set is discarded.
// 2. Clearing the primitive-only bit on any assignment whose right-hand side is
//    not provably primitive, including assignments inside nested functions and
//    assignments whose RHS names a non-primitive-only global (resolved to a
//    fixpoint). Strings and bigints are heap-allocated, so string literals,
//    templates, and bigint literals clear the bit.
//
// The scan falls back to guarded GETGLOBAL/PUTGLOBAL whenever primitiveness
// cannot be proven (such as unknown identifier RHS, member/call/new RHS, table
// overflow, or observability hazards).

const uint PRIM_MAX_CANDIDATES = 256;
// Maximum nesting tracked per delimiter during the pre-scan. The scan runs
// before the parser, so it can encounter depth that the parser later rejects.
// Stacks are indexed by raw depth; exceeding this cap drops the optimization.
const uint SLOT_MAX_NESTING = 256;
// Maximum assignments buffered per parenthesized expression while checking for
// a trailing `=>`. Exceeding this cap disqualifies the candidate immediately.
const uint SLOT_MAX_PAREN_ASSIGNS = 128;
const uint PRIM_MAX_DEPS = 8;       // Per-candidate RHS identifier dependencies

struct PrimCandidate {
    char[64] name;
    ushort   name_len;
    bool     prim_only;             // Set while still provably primitive-only
    bool     declared;              // Top-level var/function name (emit target)
    // Candidate names this RHS depends on. If any dependency is not
    // primitive-only, this candidate's primitive-only bit is cleared.
    char[64][PRIM_MAX_DEPS] deps;
    ushort[PRIM_MAX_DEPS]    dep_lens;
    uint                     dep_count;
    bool dep_overflow;              // True when dependencies exceed PRIM_MAX_DEPS
}

// Identifier names that evaluate to primitive values despite being lexed as
// IDENTIFIER tokens. Other bare identifiers in an RHS are treated as candidate
// dependencies.
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

// Identifier names that disable the primitive-only analysis for the entire unit
// due to dynamic global access or scope injection.
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

// Scans the Script global scope before compilation, populating
// prim_only_name_idxs with constant-pool indices of proven primitive-only
// top-level globals. Restores lexer state upon completion.
fn void CompilerContext.pre_scan_prim_globals(&self) {
    // Only Script global scope: modules bind via GETVAR without GETGLOBAL.
    if (!self.is_global || self.is_module) return;

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
    bool disabled = false;   // Set on observability hazard to discard results

    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[64] prev_ident;
    ushort   prev_ident_len = 0;
    bool decl_context = false;   // Inside a global `var`/`let`/`const` declarator list
    bool decl_is_var = false;    // True when the active declarator list is `var` (no TDZ)
    int  decl_paren = 0;
    int  decl_bracket = 0;
    int  decl_brace = 0;
    uint paren_depth = 0;
    uint bracket_depth = 0;
    uint brace_depth = 0;

    // RHS tracking: consumes the right-hand side of an assignment or
    // initializer for `rhs_target` and tracks if the value remains primitive.
    PrimCandidate* rhs_target = null;
    bool rhs_is_prim = true;
    int  rhs_start_paren = 0;
    int  rhs_start_bracket = 0;
    int  rhs_start_brace = 0;

    // Tracks `for (` headers to detect for-of/for-in forms where the loop
    // variable receives heap iteration values.
    bool in_for_header = false;
    int  for_header_paren = 0;   // paren_depth directly after `for (`
    bool for_saw_of_in = false;  // True if header contains `of` or `in`

    // Tracks destructuring patterns. Candidate names bound in `[`/`{` patterns
    // receive unknown or heap values and are marked non-primitive.
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

        // Observability hazards: `with`, `this`, `eval`, `globalThis`,
        // `window`, or `Function` can read or modify globals dynamically.
        if (tt == TokenType.WITH) { disabled = true; break; }
        if (tt == TokenType.THIS) { disabled = true; break; }
        if (tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            if (is_prim_observability_name(nm)) { disabled = true; break; }
        }

        // Close RHS scan when the assignment expression ends at or above
        // the starting delimiter depth.
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
                self.prim_rhs_token(tok, tt, prev_tt, rhs_target, &rhs_is_prim, table, count);
            }
        }

        switch (tt) {
            case TokenType.LPAREN:   paren_depth++;
            case TokenType.RPAREN:   if (paren_depth > 0) paren_depth--;
            case TokenType.LBRACKET: bracket_depth++;
            case TokenType.RBRACKET: if (bracket_depth > 0) bracket_depth--;
            case TokenType.LBRACE:   brace_depth++;
            case TokenType.RBRACE:   if (brace_depth > 0) brace_depth--;
            default: break;
        }

        // Detect for-of and for-in binding forms in loop headers.
        if (prev_tt == TokenType.FOR && tt == TokenType.LPAREN) {
            in_for_header = true;
            for_header_paren = (int)paren_depth;
            for_saw_of_in = false;
        }
        if (in_for_header) {
            bool is_of = (tt == TokenType.IDENTIFIER && tok.str_value == "of");
            if ((tt == TokenType.IN || is_of) && (int)paren_depth == for_header_paren) {
                for_saw_of_in = true;
            }
            if (tt == TokenType.RPAREN && (int)paren_depth < for_header_paren) {
                in_for_header = false;
            }
        }

        // `var` bindings are initialized to undefined without TDZ and qualify
        // for primitive-only optimizations. `let` and `const` have TDZ checks
        // that must throw on uninitialized access, so they remain on guarded paths.
        if (tt == TokenType.VAR || tt == TokenType.LET || tt == TokenType.CONST) {
            decl_context = true;
            decl_is_var = (tt == TokenType.VAR);
            decl_paren = (int)paren_depth;
            decl_bracket = (int)bracket_depth;
            decl_brace = (int)brace_depth;
        }

        // Detect destructuring patterns in declarations, bindings, statements,
        // or assignment contexts (`=`, `(`, `,`). Also covers array and object
        // literals in these positions; candidate identifiers in them are cleared.
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
                    // Intern unknown pattern names and clear them to prevent
                    // later dependency chains from treating them as primitive.
                    PrimCandidate* nc = prim_intern(table, &count, nm, &overflow);
                    if (overflow) { disabled = true; break; }
                    if (nc != null) nc.prim_only = false;
                }
            }
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

        // Clear for-of/for-in loop variable names once the binding form is confirmed.
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
            for_saw_of_in = false;
        }

        // Match assignment targets (`=`, compound assignments, `++`, `--`).
        if (prev_tt == TokenType.IDENTIFIER && prev_ident_len > 0) {
            char[] lhs = prev_ident[:prev_ident_len];
            bool is_simple_assign = (tt == TokenType.ASSIGN);
            bool is_compound_numeric = prim_is_numeric_compound(tt);
            bool is_compound_plus = (tt == TokenType.PLUS_ASSIGN);
            bool is_logical_assign = (tt == TokenType.LOG_AND_ASSIGN
                || tt == TokenType.LOG_OR_ASSIGN || tt == TokenType.NULLISH_ASSIGN);

            if (is_simple_assign || is_compound_numeric || is_compound_plus || is_logical_assign) {
                // Nested assignments (`a = (b = ...)`) invalidate outer target tracking.
                if (rhs_target != null) rhs_target.prim_only = false;

                PrimCandidate* c = prim_intern(table, &count, lhs, &overflow);
                if (overflow) { disabled = true; break; }
                if (c != null) {
                    // Numeric compound assignments (-=, *=, ...) always evaluate
                    // to numbers and need no RHS scan. Simple assignments, `+=`,
                    // and logical assignments propagate the RHS value.
                    if (is_compound_numeric) {
                        rhs_target = null;
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

        // Track global `var` declarations. Only `var` at top-level brace depth (0)
        // declares a global binding. Declarations inside function bodies
        // (brace_depth >= 1) declare local variables and are excluded from the
        // global emit target list. `function` declarations bind closures (heap).
        bool at_decl_depth = ((int)paren_depth == decl_paren
                              && (int)bracket_depth == decl_bracket
                              && (int)brace_depth == decl_brace);
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
        if (tt == TokenType.SEMICOLON && paren_depth == 0) decl_context = false;

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

    // Iteratively clear prim_only on candidates depending on non-candidate
    // or non-primitive names until the dependency graph stabilizes.
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

    // Record verified candidates: declared at top level and primitive-only.
    for (uint i = 0; i < count; i++) {
        if (table[i].declared && table[i].prim_only) {
            uint idx = self.add_string_constant(table[i].name[:table[i].name_len]);
            if (!self.prim_only_name_idxs.contains(idx)) {
                self.prim_only_name_idxs.push(idx);
            }
        }
    }
}

// Compound assignment operators that always produce a numeric result (excluding
// `+=` which concatenates strings, and logical assignments).
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

// Evaluates an RHS token against the current assignment target. Clears
// rhs_is_prim on heap expressions and records candidate dependencies.
fn void CompilerContext.prim_rhs_token(&self, Token tok, TokenType tt, TokenType prev_tt,
                                       PrimCandidate* target, bool* rhs_is_prim,
                                       PrimCandidate* table, uint count) {
    if (!*rhs_is_prim) return;
    switch (tt) {
        // Heap literals and object creations
        case TokenType.STRING:
        case TokenType.TEMPLATE:
        case TokenType.TEMPLATE_HEAD:
        case TokenType.TEMPLATE_MIDDLE:
        case TokenType.TEMPLATE_TAIL:
        case TokenType.REGEXP:
        case TokenType.BIGINT:
        case TokenType.LBRACE:      // Object literal
        case TokenType.LBRACKET:    // Array literal or computed property access
        case TokenType.FUNCTION:
        case TokenType.ARROW:
        case TokenType.CLASS:
        case TokenType.NEW:
        case TokenType.DOT:         // Property access (may evaluate to heap value)
        case TokenType.SUPER:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            *rhs_is_prim = false;
            target.prim_only = false;
            return;
        case TokenType.LPAREN:
            // Function call if invoked on an identifier, `)`, or `]`.
            if (prev_tt == TokenType.IDENTIFIER || prev_tt == TokenType.RPAREN
                || prev_tt == TokenType.RBRACKET) {
                *rhs_is_prim = false;
                target.prim_only = false;
            }
            return;
        case TokenType.IDENTIFIER:
            char[] nm = tok.str_value;
            if (is_primitive_ident_name(nm)) return;
            // Record bare identifier RHS as a dependency. Unknown identifiers
            // (parameters, builtins, imports) fail resolution and clear the target.
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
            // Numbers, operators, and grouping parentheses preserve primitiveness.
            return;
    }
}

// True if the constant-pool name index was proven primitive-only.
fn bool CompilerContext.is_prim_only_global(&self, uint name_idx) {
    if (self.prim_only_name_idxs.len() == 0) return false;
    return self.prim_only_name_idxs.contains(name_idx);
}

const uint SLOT_GLOBAL_MAX = 64;

// Whole-program register-resident global proof (slot_global_name_idxs).
//
// A top-level `var` global is register-resident when the unit contains no
// dynamic observability hazards (`eval`, `globalThis`, `window`, `Function`,
// `with`, `this`) and the variable is never referenced inside nested callables
// (brace_depth >= 1 or arrow bodies).
//
// Register-resident globals allocate a dedicated home register across the
// top-level script body (reads use LDREG, writes use register stores). The
// value is synced to the global object once at script completion.
//
// Ambiguous cases, observability hazards, or nested references fall back to
// the standard GETGLOBAL/PUTGLOBAL paths.
fn void CompilerContext.pre_scan_global_var_slots(&self) {
    // Only Script global scope: modules bind via GETVAR, eval may reference an
    // outer caller environment.
    if (!self.is_global || self.is_module || self.in_eval_code) return;

    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    char[64][SLOT_GLOBAL_MAX] names;
    ushort[SLOT_GLOBAL_MAX]   name_lens;
    bool[SLOT_GLOBAL_MAX]     declared;
    bool[SLOT_GLOBAL_MAX]     nested_ref;
    bool[SLOT_GLOBAL_MAX]     value_written;   // Assigned or initialized with a value
    uint count = 0;
    bool disabled = false;
    bool overflow = false;

    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[64]  prev_ident;
    ushort    prev_ident_len = 0;
    uint paren_depth = 0;
    uint bracket_depth = 0;
    uint brace_depth = 0;
    bool decl_context = false;
    int  decl_paren = 0;
    int  decl_bracket = 0;
    int  decl_brace = 0;
    // Tracks destructuring patterns. Default expressions inside patterns
    // compile into synthetic closures (compile_default_expr) that access free
    // names via the global environment. References to slot-resident globals
    // there would read stale values, so any default or binding pattern disables
    // the proof.
    bool in_destructure = false;
    int  destructure_paren = 0;
    int  destructure_bracket = 0;
    int  destructure_brace = 0;
    bool destructure_was_array = false;

    // Callable body tracking. References inside functions, arrows, methods, or
    // class bodies disqualify a global from slot residency. Top-level control
    // blocks (`if`, `for`, `while`, `switch`) share the top-level register frame
    // and do not disqualify variables.
    bool[SLOT_MAX_NESTING] paren_control;
    bool[SLOT_MAX_NESTING] brace_is_fn;
    int  cur_fn_depth = 0;      // Active nested function body count
    bool last_paren_was_control = false;
    bool class_pending = false;  // `class` body `{` is a function boundary
    // Tracks arrow expression bodies (which lack enclosing braces).
    bool arrow_active = false;
    int  arrow_paren = 0;
    int  arrow_bracket = 0;
    // Parameter defaults in `function(...)` evaluate in the callee frame;
    // marks parameter lists as nested through the matching body `{`.
    int  fn_sig_paren = -1;
    bool fn_pending = false;     // Seen `function` or `function*` before signature `(`
    // Template substitutions `${ ... }` begin with TEMPLATE_HEAD/MIDDLE and end
    // with RBRACE without opening an LBRACE. TemplateScan tracks substitution
    // depth so the closing `}` does not misdecrement block and function depths.
    TemplateScan tscan;

    // Candidates assigned in the active paren group, held until verifying
    // whether the group is an arrow parameter list followed by `=>`.
    ushort[SLOT_MAX_PAREN_ASSIGNS] pend_aidx;
    ushort[SLOT_MAX_PAREN_ASSIGNS] pend_depth;
    uint pend_count = 0;

    while (!disabled) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        Token tok = tok_opt;
        TokenType tt = tok.type;
        if (tt == TokenType.EOF_TOKEN) break;

        // Reset pending parameter assignments when returning to top level without `=>`.
        if (paren_depth == 0 && tt != TokenType.ARROW) { pend_count = 0; }

        if (tt == TokenType.WITH || tt == TokenType.THIS) { disabled = true; break; }
        if (tt == TokenType.IDENTIFIER && is_prim_observability_name(tok.str_value)) {
            disabled = true; break;
        }

        if (tt == TokenType.LPAREN) {
            paren_depth++;
            if (paren_depth >= SLOT_MAX_NESTING) { disabled = true; break; }
            paren_control[paren_depth] = slot_global_is_ctrl_paren(prev_tt);
            if (fn_pending && fn_sig_paren < 0) {
                fn_sig_paren = (int)paren_depth;
            }
            fn_pending = false;
        } else if (tt == TokenType.RPAREN) {
            if (paren_depth > 0) {
                last_paren_was_control = paren_control[paren_depth];
                paren_depth--;
            }
            if (fn_sig_paren >= 0 && paren_depth < (uint)fn_sig_paren) {
                fn_sig_paren = -1;
            }
        } else if (tt == TokenType.LBRACE) {
            // A `{` is a function body when following `=>`, a non-control `)`,
            // or a `class` header. Otherwise it is treated as a block.
            tscan.on_lbrace();
            bool is_fn = prev_tt == TokenType.ARROW
                || (prev_tt == TokenType.RPAREN && !last_paren_was_control)
                || class_pending;
            class_pending = false;
            brace_depth++;
            if (brace_depth >= SLOT_MAX_NESTING) { disabled = true; break; }
            brace_is_fn[brace_depth] = is_fn;
            if (is_fn) { cur_fn_depth++; }
            if (arrow_active) { arrow_active = false; }
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            tscan.on_template_head();
        } else if (tt == TokenType.RBRACE) {
            if (tscan.classify_rbrace(self.lexer) == TemplateBrace.BLOCK) {
                if (brace_depth > 0) {
                    if (brace_is_fn[brace_depth]) { cur_fn_depth--; }
                    brace_depth--;
                }
            }
        } else if (tt == TokenType.LBRACKET) {
            bracket_depth++;
        } else if (tt == TokenType.RBRACKET) {
            if (bracket_depth > 0) bracket_depth--;
        } else if (tt == TokenType.ARROW) {
            // Parameter defaults evaluate in thunks via the environment chain.
            // Mark variables assigned in the parameter list as nested.
            if (prev_tt == TokenType.RPAREN) {
                for (uint k = 0; k < pend_count; k++) {
                    if ((uint)pend_depth[k] > paren_depth) { nested_ref[pend_aidx[k]] = true; }
                }
            }
            arrow_active = true;
            arrow_paren = (int)paren_depth;
            arrow_bracket = (int)bracket_depth;
        } else if (tt == TokenType.FUNCTION) {
            fn_pending = true;
        } else if (tt == TokenType.CLASS) {
            class_pending = true;
        }

        if (arrow_active) {
            if (tt == TokenType.SEMICOLON && paren_depth == 0) { arrow_active = false; }
            else if (tt == TokenType.COMMA
                     && (int)paren_depth <= arrow_paren
                     && (int)bracket_depth <= arrow_bracket) { arrow_active = false; }
            else if (tt == TokenType.RPAREN && (int)paren_depth < arrow_paren) { arrow_active = false; }
            else if (tt == TokenType.RBRACKET && (int)bracket_depth < arrow_bracket) { arrow_active = false; }
            else if (tt == TokenType.RBRACE && brace_depth == 0) { arrow_active = false; }
        }

        if (tt == TokenType.VAR || tt == TokenType.LET || tt == TokenType.CONST) {
            decl_context = true;
            decl_paren = (int)paren_depth;
            decl_bracket = (int)bracket_depth;
            decl_brace = (int)brace_depth;
        }

        // Destructuring patterns: defaults inside patterns run in synthetic
        // closures that read free names through the environment.
        if (!in_destructure && (tt == TokenType.LBRACKET || tt == TokenType.LBRACE)) {
            bool after_decl = (prev_tt == TokenType.VAR || prev_tt == TokenType.LET
                               || prev_tt == TokenType.CONST);
            bool stmt_start = (prev_tt == TokenType.SEMICOLON || prev_tt == TokenType.LBRACE
                               || prev_tt == TokenType.RBRACE || prev_tt == TokenType.EOF_TOKEN);
            bool after_assign_ctx = (prev_tt == TokenType.ASSIGN || prev_tt == TokenType.LPAREN
                               || prev_tt == TokenType.COMMA);
            if (after_decl || stmt_start || after_assign_ctx) {
                in_destructure = true;
                destructure_was_array = (tt == TokenType.LBRACKET);
                destructure_paren = (int)paren_depth;
                destructure_bracket = (int)bracket_depth;
                destructure_brace = (int)brace_depth;
            }
        }
        if (in_destructure) {
            // Default assignments (`=`) inside the pattern run through closures.
            int cur = destructure_was_array ? (int)bracket_depth : (int)brace_depth;
            int entry = destructure_was_array ? destructure_bracket : destructure_brace;
            if (tt == TokenType.ASSIGN && cur >= entry) { disabled = true; break; }
            // Pattern ends when delimiter depth drops below entry depth and
            // encounters a boundary token.
            bool close_pat = false;
            if (cur < entry) {
                if (tt == TokenType.ASSIGN || tt == TokenType.SEMICOLON
                    || tt == TokenType.RPAREN || tt == TokenType.IN
                    || (tt == TokenType.IDENTIFIER && tok.str_value == "of")) {
                    close_pat = true;
                }
            }
            if (close_pat) {
                // Binding patterns write targets through environment operations,
                // desyncing register-allocated globals.
                disabled = true; break;
            }
        }

        // `for (x in obj)` assigns the iteration variable via the environment.
        if (tt == TokenType.IN && paren_control[paren_depth]) { disabled = true; break; }

        bool in_fn = cur_fn_depth > 0 || arrow_active
            || (fn_sig_paren >= 0 && paren_depth >= (uint)fn_sig_paren);

        if (tt == TokenType.IDENTIFIER) {
            char[] nm = tok.str_value;
            int idx = slot_global_find(&names[0], &name_lens[0], count, nm);
            bool top_decl = brace_depth == 0 && !in_fn
                && (prev_tt == TokenType.VAR
                    || (decl_context
                        && prev_tt == TokenType.COMMA
                        && (int)paren_depth == decl_paren
                        && (int)bracket_depth == decl_bracket
                        && (int)brace_depth == decl_brace));
            if (top_decl) {
                if (idx < 0) {
                    idx = slot_global_intern(&names[0], &name_lens[0], &count, nm);
                    if (idx < 0) { overflow = true; break; }
                }
                declared[idx] = true;
            } else if (in_fn) {
                // References in nested callables read the global property
                // rather than the top-level register. Disqualify the candidate.
                if (idx < 0) {
                    int ni = slot_global_intern(&names[0], &name_lens[0], &count, nm);
                    if (ni < 0) { overflow = true; break; }
                    idx = ni;
                }
                nested_ref[idx] = true;
            }
        }

        if (tt == TokenType.SEMICOLON && paren_depth == 0) decl_context = false;

        // Assignments and updates record variables that require property
        // synchronization at script completion. Bare `var x;` declarations
        // do not write properties and are skipped.
        if (slot_global_is_assign_op(tt) && prev_tt == TokenType.IDENTIFIER && prev_ident_len > 0) {
            int aidx = slot_global_find(&names[0], &name_lens[0], count,
                                        prev_ident[:prev_ident_len]);
            if (aidx >= 0) {
                value_written[aidx] = true;
                if (paren_depth > 0) {
                    if (pend_count < SLOT_MAX_PAREN_ASSIGNS) {
                        pend_aidx[pend_count]  = (ushort)aidx;
                        pend_depth[pend_count] = (ushort)paren_depth;
                        pend_count++;
                    } else {
                        nested_ref[aidx] = true;
                    }
                }
            }
        }

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

    for (uint i = 0; i < count; i++) {
        if (declared[i] && !nested_ref[i]) {
            // Function declaration bindings live in the environment (DECLGLOBALFUNC).
            // Retain GETGLOBAL/PUTGLOBAL paths for names sharing a top-level
            // FunctionDeclaration to prevent reading uninitialized register slots.
            bool is_fn_decl = false;
            for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                if (str_eq(self.hoisted_fn_names[hi], names[i][:name_lens[i]])) {
                    is_fn_decl = true;
                    break;
                }
            }
            if (is_fn_decl) { continue; }

            uint idx = self.add_string_constant(names[i][:name_lens[i]]);
            if (!self.slot_global_name_idxs.contains(idx)) {
                self.slot_global_name_idxs.push(idx);
            }
            // Only sync values to the global property if an assignment or
            // initializer occurred; bare declarations do not overwrite properties.
            if (value_written[i] && !self.slot_global_synced_name_idxs.contains(idx)) {
                self.slot_global_synced_name_idxs.push(idx);
            }
        }
    }
}

fn int slot_global_find(char[64]* names, ushort* name_lens, uint count, char[] nm) {
    if (nm.len == 0) return -1;
    for (uint i = 0; i < count; i++) {
        if (name_lens[i] == nm.len) {
            bool same = true;
            for (usz j = 0; j < nm.len; j++) {
                if (names[i][j] != nm[j]) { same = false; break; }
            }
            if (same) return (int)i;
        }
    }
    return -1;
}

fn int slot_global_intern(char[64]* names, ushort* name_lens, uint* count, char[] nm) {
    uint c = *count;
    if (nm.len == 0 || nm.len > 63 || c >= SLOT_GLOBAL_MAX) return -1;
    for (usz j = 0; j < nm.len; j++) names[c][j] = nm[j];
    name_lens[c] = (ushort)nm.len;
    (*count)++;
    return (int)c;
}

// True if `t` opens a control-structure condition (such as `if`, `for`,
// `while`) whose closing `)` leads to a block statement rather than a callable body.
fn bool slot_global_is_ctrl_paren(TokenType t) {
    switch (t) {
        case TokenType.FOR:
        case TokenType.IF:
        case TokenType.WHILE:
        case TokenType.SWITCH:
        case TokenType.CATCH:
        case TokenType.WITH:
            return true;
        default:
            return false;
    }
}

// True if `t` is an assignment or increment/decrement operator that writes
// into the preceding identifier target.
fn bool slot_global_is_assign_op(TokenType t) {
    switch (t) {
        case TokenType.ASSIGN:
        case TokenType.PLUS_ASSIGN:
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
        case TokenType.LOG_AND_ASSIGN:
        case TokenType.LOG_OR_ASSIGN:
        case TokenType.NULLISH_ASSIGN:
        case TokenType.INC:
        case TokenType.DEC:
            return true;
        default:
            return false;
    }
}

