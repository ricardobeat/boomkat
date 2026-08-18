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

/// Record a name referenced inside a nested callable body.
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

/// Is this local name captured by a nested callable (or is everything)?
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

/// Token pre-scan collecting captured names for the function body that the
/// lexer is currently positioned at. Mirrors hoist_decls' conventions:
/// for a block body, call with the lexer BEFORE the body's `{`; the scan
/// stops at the matching `}`. For an expression body (`expr_mode`, arrows),
/// the scan stops when the expression ends (a closer below the entry depth,
/// or a top-level `,` / `;`). The lexer state is fully restored on return.
fn void CompilerContext.pre_scan_captures(&self, bool expr_mode = false) {
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

    uint brace_depth = 0;        // `{`/`}` nesting within the scanned span
    TemplateScan tscan;          // template-aware `}` classification (see template_scan.c3)
    int  combined_depth = 0;     // parens + brackets + braces (expression extents)
    int  region_depth = -1;      // brace_depth where the outermost callable body began
    int  expr_region_depth = -1; // combined_depth of an expression-bodied arrow
    bool started = false;        // block mode: saw the body's opening `{`

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
        }

        if (tt == TokenType.LBRACE) {
            tscan.on_lbrace();
            if ((was_pending_brace || was_pending_arrow) && region_depth < 0) {
                region_depth = (int)brace_depth;
                // Flush deferred param-default capture buffer: identifiers
                // seen inside the `(...)` that preceded this `{` are in
                // parameter-default expressions and must be captured.
                if (param_buf_count > 0) {
                    for (uint pi = 0; pi < param_buf_count; pi++) {
                        self.add_captured_name(param_buf_names[pi][:param_buf_lens[pi]]);
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
                if (!expr_mode && started && brace_depth == 0) {
                    done = true;  // body's closing brace
                }
                if (region_depth >= 0 && (int)brace_depth <= region_depth) region_depth = -1;
                if (expr_region_depth >= 0 && combined_depth < expr_region_depth) expr_region_depth = -1;
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
            if (expr_region_depth >= 0 && combined_depth < expr_region_depth) expr_region_depth = -1;
        } else if (tt == TokenType.LBRACKET) {
            combined_depth++;
        } else if (tt == TokenType.RBRACKET) {
            combined_depth--;
            if (expr_mode && combined_depth < 0) done = true;
            if (expr_region_depth >= 0 && combined_depth < expr_region_depth) expr_region_depth = -1;
        } else if (tt == TokenType.ARROW) {
            pending_arrow = true;
        } else if (tt == TokenType.CLASS) {
            // Class field initializers run in constructor scope with no
            // `) {` marker, so degrade rather than miss captures. Unlike
            // class_kw_starts_class in functions.c3, no lookahead gate is
            // applied here: this scan works on raw token streams without
            // lexer restore, and the over-approximation is safe (captures
            // more, never fewer).
            self.capture_all = true;
        } else if (tt == TokenType.COMMA || tt == TokenType.SEMICOLON
                   || tt == TokenType.COLON) {
            if (expr_region_depth >= 0 && combined_depth == expr_region_depth) {
                expr_region_depth = -1;
            }
            if (expr_mode && combined_depth == 0 && tt != TokenType.COLON
                && region_depth < 0) {
                done = true;  // end of arrow expression body
            }
        } else if (tt == TokenType.IDENTIFIER) {
            char[] name = tok.str_value;
            if (name.len == 4 && name[0] == 'e' && name[1] == 'v'
                && name[2] == 'a' && name[3] == 'l') {
                // Direct eval can read/assign any caller binding by name.
                self.capture_all = true;
            } else if (region_depth >= 0 || expr_region_depth >= 0) {
                self.add_captured_name(name);
            }
            // Buffer identifiers seen inside a non-control `(...)` so they
            // can be captured if the paren turns out to be a param list.
            if (param_buf_active && param_buf_count < 16 && region_depth < 0) {
                param_buf_names[param_buf_count] = name;
                param_buf_lens[param_buf_count] = (ushort)name.len;
                param_buf_count++;
            }
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
