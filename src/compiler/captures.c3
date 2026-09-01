module boomkat::compiler;

import boomkat::lexer;
import std::io;

// ============================================================================
// Capture pre-scan (plan 045)
//
// Locals referenced by nested callables (functions, methods, getters/setters,
// arrows) or reachable by direct eval must be environment-resident: closures
// and eval read/write the env copy, so a register copy in the outer function
// would go stale in either direction. The pre-scan walks the body's tokens
// before it is compiled and collects every identifier that appears inside a
// nested callable body; declare_var marks matching locals is_captured, which
// routes all their access through GETVAR/PUTVAR.
//
// Callable-body detection is token-level and deliberately overapproximate
// (false positives only cost env round-trips on that name, never wrong
// values):
//   - `) {` opens a callable body unless the `(` was preceded by a control
//     keyword (if/for/while/switch/catch). This uniformly catches function
//     declarations/expressions, methods, getters/setters, generators, and
//     class methods. The rare `f()` expression statement followed by a block
//     statement is a harmless false positive.
//   - `=> {` opens a callable body; an expression-bodied arrow collects until
//     the expression ends (bracket depth drops below the arrow's, or a
//     top-level `,` / `;` / `:` at the arrow's depth).
//   - `class` bodies degrade to capture_all: field initializers run in
//     constructor scope and can reference outer locals without any `) {`.
//   - The identifier `eval` anywhere degrades to capture_all: a direct eval
//     can read and assign any caller binding by name.
//   - Table overflow (more distinct names than the fixed capacity, or a name
//     longer than the slot) degrades to capture_all.
// ============================================================================

fn bool is_control_paren_kw(TokenType tt) {
    return tt == TokenType.IF || tt == TokenType.FOR || tt == TokenType.WHILE
        || tt == TokenType.SWITCH || tt == TokenType.CATCH;
}

// Record a name referenced inside a nested callable body.
fn void CompilerContext.add_captured_name(&self, char[] name) {
    if (self.capture_all) return;
    if (name.len == 0) return;
    if (name.len > 63) { self.capture_all = true; return; }
    for (uint i = 0; i < self.captured_count; i++) {
        if (self.captured_name_lens[i] == name.len) {
            bool same = true;
            for (usz j = 0; j < name.len; j++) {
                if (self.captured_names[i][j] != name[j]) { same = false; break; }
            }
            if (same) return;
        }
    }
    if (self.captured_count >= MAX_CAPTURED_NAMES) { self.capture_all = true; return; }
    for (usz j = 0; j < name.len; j++) self.captured_names[self.captured_count][j] = name[j];
    self.captured_name_lens[self.captured_count] = (ushort)name.len;
    self.captured_count++;
}

// Is this local name captured by a nested callable (or is everything)?
fn bool CompilerContext.is_captured_name(&self, char[] name) {
    if (self.capture_all) return true;
    for (uint i = 0; i < self.captured_count; i++) {
        if (self.captured_name_lens[i] == name.len) {
            bool same = true;
            for (usz j = 0; j < name.len; j++) {
                if (self.captured_names[i][j] != name[j]) { same = false; break; }
            }
            if (same) return true;
        }
    }
    return false;
}

// Token pre-scan collecting captured names for the function body that the
// lexer is currently positioned at. Mirrors hoist_decls' conventions:
// for a block body, call with the lexer BEFORE the body's `{`; the scan
// stops at the matching `}`. For an expression body (`expr_mode`, arrows),
// the scan stops when the expression ends (a closer below the entry depth,
// or a top-level `,` / `;`). The lexer state is fully restored on return.
fn void CompilerContext.pre_scan_captures(&self, bool expr_mode = false, bool global_mode = false) {
    // --- Save lexer state ---
    ForLhsSnapshot snap = self.save_lhs_snapshot();

    uint brace_depth = 0;        // `{`/`}` nesting within the scanned span
    TemplateScan tscan;          // template-aware `}` classification (see template_scan.c3)
    int  combined_depth = 0;     // parens + brackets + braces (expression extents)
    int  region_depth = -1;      // brace_depth where the outermost callable body began
    int  expr_region_depth = -1; // combined_depth of an expression-bodied arrow
    // Global scripts have no outer `{`, so the scan starts immediately and
    // runs until EOF. For function bodies the scan waits for the opening `{`.
    bool started = global_mode;

    // Paren context stack: was each `(` preceded by a control keyword?
    bool[64] paren_ctrl;
    uint paren_depth = 0;
    TokenType prev_tt = TokenType.EOF_TOKEN;
    bool pending_body_brace = false;  // `) {` opens a callable body
    bool pending_arrow = false;       // just saw `=>`; body shape unknown

    // Deferred capture buffer for parameter-default expressions: identifiers
    // seen inside a non-control `(...)` that is followed by `{` (a param list)
    // must be captured even though they appear outside any callable body.
    // Buffered when entering a non-control `(`, flushed on `) {`, discarded
    // on any other token after `)`.
    char[][16] param_buf_names;       // buffered identifier names
    ushort[16] param_buf_lens;
    uint param_buf_count = 0;
    bool param_buf_active = false;    // true while inside a non-control `(`
    int param_buf_base_paren = -1;    // paren_depth of the opening `(`
    bool param_buf_pending = false;   // `)` seen, waiting for `{` or discard

    // --- Shadow set: parameter names bound by the innermost callable ---
    // A name a nested callable binds as its own parameter cannot refer to the
    // outer local of the same name, so references to it inside that callable
    // must NOT mark the outer local captured. Only simple `(a, b)` / `a =>`
    // parameter positions qualify: a name appearing anywhere else in the list
    // (inside a default expression, or a destructuring pattern) is a
    // reference, not a binder, so it is left out and stays capturing.
    //
    // The set is also extended by the body's own top-level `var`/`let`/`const`
    // binders (see decl_pending below), which covers a nested callable that
    // redeclares an outer name rather than taking it as a parameter.
    //
    // The set is only consulted while region_depth marks the body that these
    // parameters belong to, and it is cleared when that body closes. Nested
    // callables deeper in are not tracked -- shadow_valid goes false for them,
    // which falls back to the old capture-everything behaviour.
    char[][16] shadow_names;
    ushort[16] shadow_lens;
    uint shadow_count = 0;
    bool shadow_valid = false;        // set is complete/trustworthy for region_depth
    // Candidate binders accumulated while scanning the current param list.
    char[][16] cand_names;
    ushort[16] cand_lens;
    uint cand_count = 0;
    bool cand_ok = true;              // false once the list has a non-simple form
    int  cand_paren = -1;             // paren_depth just inside the param list
    int  cand_cdepth = -1;            // combined_depth just inside the param list
    // An identifier in binder position, confirmed by the next token.
    char[] pend_name;
    ushort pend_len = 0;
    bool   pend_active = false;
    // Most recent identifier token, for the parenless `x => ...` arrow form.
    char[] last_ident;
    ushort last_ident_len = 0;

    // --- Shadow set extension: body-level `var`/`let`/`const` binders ---
    // A nested callable that declares its own body-level binding of a name
    // cannot reach the outer local of that name, so references to it inside
    // that callable must not mark the outer local captured.
    //
    // Only the callable body's OWN top level qualifies (`brace_depth ==
    // region_depth + 1`). A declaration in a nested block shadows just that
    // block, so `() => { const a = s; { let s = 9; } }` must still capture the
    // outer `s`; restricting to body level is what keeps that sound. `var`
    // hoists to the whole body, and a body-level `let`/`const` covers every
    // point a nested closure could read the name from, so both are safe here.
    bool decl_pending = false;    // inside a body-level declarator list
    bool decl_at_binder = false;  // next identifier is a binding identifier
    int  decl_cdepth = -1;        // combined_depth of the declarator list

    bool done = false;
    while (!done && !self.capture_all) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        Token tok = tok_opt;
        TokenType tt = tok.type;
        if (tt == TokenType.EOF_TOKEN) break;

        bool was_pending_brace = pending_body_brace;
        bool was_pending_arrow = pending_arrow;
        pending_body_brace = false;
        pending_arrow = false;

        // Resolve a parameter-binder candidate against the token that follows
        // it: only `,` or `)` confirm a simple binder. Anything else (`=`,
        // `.`, `[`, ...) means the identifier was a reference or a non-simple
        // pattern element, which disqualifies the whole list from shadowing.
        if (pend_active) {
            pend_active = false;
            if (tt == TokenType.COMMA || tt == TokenType.RPAREN) {
                if (cand_count < 16) {
                    cand_names[cand_count] = pend_name;
                    cand_lens[cand_count] = pend_len;
                    cand_count++;
                } else {
                    cand_ok = false;
                }
            } else {
                cand_ok = false;
            }
        }

        // If `)` was seen but the next token is not `{`, this was a call or
        // grouping expression, not a param list, so discard the deferred buffer.
        if (param_buf_pending && tt != TokenType.LBRACE && tt != TokenType.ARROW) {
            param_buf_pending = false;
            param_buf_count = 0;
        }

        // An expression-bodied arrow (`=>` followed by anything but `{`)
        // collects from here until its expression ends.
        if (was_pending_arrow && tt != TokenType.LBRACE
            && region_depth < 0 && expr_region_depth < 0) {
            expr_region_depth = combined_depth;
            // Same shadow adoption as a braced body, for `(a, b) => expr`.
            shadow_count = 0;
            shadow_valid = false;
            if (cand_ok && cand_count > 0) {
                for (uint ci = 0; ci < cand_count; ci++) {
                    shadow_names[ci] = cand_names[ci];
                    shadow_lens[ci] = cand_lens[ci];
                }
                shadow_count = cand_count;
                shadow_valid = true;
            }
        }

        if (tt == TokenType.LBRACE) {
            tscan.on_lbrace();
            if ((was_pending_brace || was_pending_arrow) && region_depth >= 0) {
                // A callable nested inside the region we are already tracking.
                // Its own binders are not modelled, so stop trusting the outer
                // shadow set for the rest of this region: fall back to
                // capturing every name, as before.
                shadow_valid = false;
                shadow_count = 0;
                // Any declarator list in progress belonged to the outer body;
                // declarations inside this deeper callable must not extend it.
                decl_pending = false;
                decl_at_binder = false;
            }
            if ((was_pending_brace || was_pending_arrow) && region_depth < 0) {
                region_depth = (int)brace_depth;
                // This body belongs to the parameter list just scanned: adopt
                // its simple binders as the shadow set for the whole region.
                // An empty list still yields a valid (empty) set, so a nested
                // callable taking no parameters can still shadow via its own
                // body-level declarations below.
                shadow_count = 0;
                shadow_valid = false;
                decl_pending = false;
                decl_at_binder = false;
                if (cand_ok) {
                    for (uint ci = 0; ci < cand_count; ci++) {
                        shadow_names[ci] = cand_names[ci];
                        shadow_lens[ci] = cand_lens[ci];
                    }
                    shadow_count = cand_count;
                    shadow_valid = true;
                }
                // Flush deferred param-default capture buffer: identifiers
                // seen inside the `(...)` that preceded this `{` are in
                // parameter-default expressions and must be captured.
                //
                // Confirmed simple binders are skipped: `function (s, i)` names
                // the parameters themselves, which shadow rather than reference
                // the outer locals. A name that is BOTH a binder and a
                // reference elsewhere in the list (`(a = s, s)`) still flushes,
                // because it only reaches the binder set when every one of its
                // occurrences sat in binder position.
                if (param_buf_count > 0) {
                    for (uint pi = 0; pi < param_buf_count; pi++) {
                        char[] pn = param_buf_names[pi][:param_buf_lens[pi]];
                        bool is_binder = false;
                        if (shadow_valid) {
                            for (uint si = 0; si < shadow_count; si++) {
                                if (shadow_lens[si] != pn.len) continue;
                                bool same = true;
                                for (usz j = 0; j < pn.len; j++) {
                                    if (shadow_names[si][j] != pn[j]) { same = false; break; }
                                }
                                if (same) { is_binder = true; break; }
                            }
                        }
                        if (!is_binder) self.add_captured_name(pn);
                    }
                }
            }
            param_buf_pending = false;
            param_buf_count = 0;
            if (!expr_mode && !started && brace_depth == 0) started = true;
            brace_depth++;
            combined_depth++;
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            // The lexer consumed `...${; the expression tokens follow, then a
            // RBRACE that belongs to the template substitution, not any JS block.
            tscan.on_template_head();
        } else if (tt == TokenType.RBRACE) {
            TemplateBrace tb = tscan.classify_rbrace(self.lexer);
            if (tb == TemplateBrace.LEX_ERROR) break;
            if (tb == TemplateBrace.SUBST) {
                // Substitution closed; template part consumed. Not a JS block.
            } else if (brace_depth == 0) {
                done = true;  // underflow: end of expr-mode span or malformed input
            } else {
                brace_depth--;
                combined_depth--;
                // For function bodies, brace_depth returning to 0 means the
                // body's closing `}`.  For global scripts (no outer `{}`),
                // brace_depth 0 is the top level, so keep scanning until EOF.
                if (!expr_mode && started && brace_depth == 0 && !global_mode) {
                    done = true;  // body's closing brace
                }
                if (region_depth >= 0 && (int)brace_depth <= region_depth) {
                    region_depth = -1;
                    shadow_valid = false;
                    shadow_count = 0;
                    decl_pending = false;
                    decl_at_binder = false;
                }
                if (expr_region_depth >= 0 && combined_depth < expr_region_depth) { expr_region_depth = -1; shadow_valid = false; shadow_count = 0; }
            }
        } else if (tt == TokenType.LPAREN) {
            if (paren_depth < 64) {
                bool is_ctrl = is_control_paren_kw(prev_tt);
                paren_ctrl[paren_depth] = is_ctrl;
                if (!is_ctrl && !param_buf_active && region_depth < 0) {
                    param_buf_active = true;
                    param_buf_base_paren = (int)paren_depth;
                    param_buf_count = 0;
                    param_buf_pending = false;
                    // Start collecting simple binder names for this list.
                    cand_count = 0;
                    cand_ok = true;
                    cand_paren = (int)paren_depth + 1;
                    cand_cdepth = combined_depth + 1;
                }
            } else {
                self.capture_all = true;
            }
            paren_depth++;
            combined_depth++;
        } else if (tt == TokenType.RPAREN) {
            if (paren_depth > 0) {
                paren_depth--;
                if (!paren_ctrl[paren_depth]) pending_body_brace = true;
                if (param_buf_active && (int)paren_depth == param_buf_base_paren) {
                    param_buf_active = false;
                    param_buf_pending = true;
                }
            }
            combined_depth--;
            if (expr_mode && combined_depth < 0) {
                done = true;  // closer below the arrow expression's entry depth
            }
            if (expr_region_depth >= 0 && combined_depth < expr_region_depth) { expr_region_depth = -1; shadow_valid = false; shadow_count = 0; }
        } else if (tt == TokenType.LBRACKET) {
            combined_depth++;
        } else if (tt == TokenType.RBRACKET) {
            combined_depth--;
            if (expr_mode && combined_depth < 0) done = true;
            if (expr_region_depth >= 0 && combined_depth < expr_region_depth) { expr_region_depth = -1; shadow_valid = false; shadow_count = 0; }
        } else if (tt == TokenType.ARROW) {
            pending_arrow = true;
            // A parenless arrow (`x => ...`) binds the single identifier that
            // immediately precedes the `=>`, with no param-list parens for the
            // candidate machinery to have seen. Adopt it directly. When the
            // arrow did have parens, `)` was the previous token and the
            // candidate set built above already holds the binders.
            if (prev_tt == TokenType.IDENTIFIER && region_depth < 0
                && expr_region_depth < 0 && last_ident_len > 0) {
                cand_names[0] = last_ident;
                cand_lens[0] = last_ident_len;
                cand_count = 1;
                cand_ok = true;
            }
        } else if (tt == TokenType.CLASS) {
            // Class field initializers run in constructor scope with no
            // `) {` marker, so degrade rather than miss captures. Unlike
            // class_kw_starts_class in functions.c3, no lookahead gate is
            // applied here: this scan works on raw token streams without
            // lexer restore, and the over-approximation is safe (captures
            // more, never fewer).
            self.capture_all = true;
        } else if (tt == TokenType.VAR || tt == TokenType.LET
                   || tt == TokenType.CONST) {
            // A declaration at the tracked callable body's own top level binds
            // names that shadow the outer local. `for (var i = 0; ...)` also
            // lands here: its header sits one paren deeper, and decl_cdepth
            // records that so the header's `,` separators are still binders.
            if (region_depth >= 0 && (int)brace_depth == region_depth + 1) {
                decl_pending = true;
                decl_at_binder = true;
                decl_cdepth = combined_depth;
            } else {
                decl_pending = false;
                decl_at_binder = false;
            }
        } else if (tt == TokenType.COMMA || tt == TokenType.SEMICOLON
                   || tt == TokenType.COLON) {
            if (decl_pending) {
                if (tt == TokenType.SEMICOLON) {
                    // Ends the declaration (or the init clause of a for-head).
                    decl_pending = false;
                    decl_at_binder = false;
                } else if (tt == TokenType.COMMA && combined_depth == decl_cdepth) {
                    // A `,` at the declarator list's own depth continues the
                    // list, so the next identifier is another binder. A `,`
                    // nested inside a call, array or object in an initialiser
                    // is deeper and correctly leaves decl_at_binder false.
                    decl_at_binder = true;
                } else if (tt == TokenType.COLON) {
                    // Object-pattern value position / ternary: not a binder.
                    decl_at_binder = false;
                }
            }
            if (expr_region_depth >= 0 && combined_depth == expr_region_depth) {
                expr_region_depth = -1;
                shadow_valid = false;
                shadow_count = 0;
            }
            if (expr_mode && combined_depth == 0 && tt != TokenType.COLON
                && region_depth < 0) {
                done = true;  // end of arrow expression body
            }
        } else if (tt == TokenType.ASSIGN) {
            if (decl_pending) decl_at_binder = false;  // initialiser follows
        } else if (tt == TokenType.IDENTIFIER) {
            char[] name = tok.str_value;
            last_ident = name;
            last_ident_len = (ushort)name.len;
            // A binding identifier of a body-level declarator shadows the
            // outer local of the same name. Both depth tests must hold: the
            // declaration is at the body's own top level, and the name sits at
            // the declarator list's own depth rather than inside a
            // destructuring pattern, call, or index in an initialiser. A
            // pattern leaf is therefore skipped, which only over-captures.
            if (decl_at_binder && region_depth >= 0
                && (int)brace_depth == region_depth + 1
                && combined_depth == decl_cdepth) {
                decl_at_binder = false;
                if (shadow_valid && shadow_count < 16) {
                    shadow_names[shadow_count] = name;
                    shadow_lens[shadow_count] = (ushort)name.len;
                    shadow_count++;
                }
            }
            if (name.len == 4 && name[0] == 'e' && name[1] == 'v'
                && name[2] == 'a' && name[3] == 'l') {
                // Direct eval can read/assign any caller binding by name.
                self.capture_all = true;
            } else if (region_depth >= 0 || expr_region_depth >= 0) {
                // Skip names the innermost callable binds as its own simple
                // parameters: those references resolve to the parameter, never
                // to the outer local, so the outer local stays register-resident.
                bool shadowed = false;
                if (shadow_valid) {
                    for (uint si = 0; si < shadow_count; si++) {
                        if (shadow_lens[si] != name.len) continue;
                        bool same = true;
                        for (usz j = 0; j < name.len; j++) {
                            if (shadow_names[si][j] != name[j]) { same = false; break; }
                        }
                        if (same) { shadowed = true; break; }
                    }
                }
                if (!shadowed) self.add_captured_name(name);
            }
            // Buffer identifiers seen inside a non-control `(...)` so they
            // can be captured if the paren turns out to be a param list.
            if (param_buf_active && region_depth < 0) {
                if (param_buf_count < 16) {
                    param_buf_names[param_buf_count] = name;
                    param_buf_lens[param_buf_count] = (ushort)name.len;
                    param_buf_count++;
                } else {
                    // Overflowed the deferred buffer: names beyond it would be
                    // dropped, so no binder claim from this list is trustworthy.
                    cand_ok = false;
                }
                // A binder is an identifier sitting directly at the top level
                // of the list (`(a, b)`), i.e. exactly one paren deep and not
                // nested in a default expression, array/object pattern, or
                // call. It is only *confirmed* once the following token turns
                // out to be `,` or `)`, which rejects `a = s` (default), `a.b`
                // (member expression) and any other continuation.
                if ((int)paren_depth == cand_paren && combined_depth == cand_cdepth) {
                    pend_name = name;
                    pend_len = (ushort)name.len;
                    pend_active = true;
                }
            }
        }

        prev_tt = tt;
    }

    // --- Restore lexer state ---
    self.restore_lhs_snapshot(snap);

    // Parameters (and destructured-parameter leaves) were declared before
    // this scan ran, so retroactively mark any the capture set names. Their
    // env copies already exist (param DECLVARs), so flipping reads to GETVAR
    // is safe.
    if (!self.is_global) {
        for (uint i = 0; i < self.scope_depth; i++) {
            if (self.scope_stack[i].kind == SCOPEMARK) continue;
            if (!self.scope_stack[i].is_captured
                && self.is_captured_name(self.scope_stack[i].name)) {
                self.scope_stack[i].is_captured = true;
                self.has_captured_local = true;
            }
        }
    }
}
