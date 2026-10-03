module boomkat::compiler;

import boomkat::lexer;
import boomkat::relexstats;

// Maximum nesting tracked per delimiter during the pre-scan. The scan runs
// before the parser, so it can encounter depth that the parser later rejects.
// Stacks are indexed by raw depth; exceeding this cap drops the optimization.
const uint SLOT_MAX_NESTING = 256;
// Maximum assignments buffered per parenthesized expression while checking for
// a trailing `=>`. Exceeding this cap disqualifies the candidate immediately.
const uint SLOT_MAX_PAREN_ASSIGNS = 128;
const uint SLOT_GLOBAL_MAX = 64;

// Register-resident module variable proof (slot_global_name_idxs).
//
// A module's top-level `var` is register-resident when the body contains no
// direct `eval` or `with` and the variable is never referenced inside nested
// callables (brace_depth >= 1 or arrow bodies). The binding lives in the
// module environment, which only direct `eval`, nested callables, and
// importers can reach. Following V8's and JSC's module scope allocation, an
// exported name stays in the environment, where importers' live bindings read
// it; any other binding is invisible outside the body, so it needs no sync.
//
// Scripts get no such proof: a Script's var is a global object property, and
// code from another script (an earlier script's function, or one evaluated
// mid-run by the host) can read or write it at any call.
//
// Register-resident globals allocate a dedicated home register across the
// top-level body (reads use LDREG, writes use register stores). Ambiguous
// cases, observability hazards, or nested references fall back to the
// standard GETGLOBAL/PUTGLOBAL paths.
fn void CompilerContext.pre_scan_global_var_slots(&self) {
    relexstats::RelexKind relex_prev = relexstats::relex_enter(relexstats::RelexKind.GLOBAL_VAR_SLOTS);
    defer relexstats::relex_leave(relex_prev);
    // Eval code may reference an outer caller environment.
    if (!self.is_module || self.in_eval_code) return;

    ForLhsSnapshot snap = self.save_lhs_snapshot();
    // Regex and template tracking for this scan; the snapshot restore turns it off.
    self.lexer.hint = lexer::scan_hint_start(self.lexer.current.type, false);

    char[64][SLOT_GLOBAL_MAX] names;
    ushort[SLOT_GLOBAL_MAX]   name_lens;
    bool[SLOT_GLOBAL_MAX]     declared;
    bool[SLOT_GLOBAL_MAX]     nested_ref;
    bool[SLOT_GLOBAL_MAX]     exported;        // Named by an export
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
    // `export var ...`: the declaration's names are exported.
    bool decl_exported = false;
    // Brace depth of an open `export { ... }` clause, or 0. Every identifier in
    // it counts as exported, aliases included: a false positive only keeps a
    // name in the environment.
    uint export_list_brace = 0;
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
    // Set on the token that closes the candidate; the token after it decides
    // whether the candidate was a pattern or a literal.
    bool destructure_closed = false;

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

        if (tt == TokenType.WITH) { disabled = true; break; }
        if (tt == TokenType.IDENTIFIER && tok.str_value == "eval") { disabled = true; break; }

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
            if (prev_tt == TokenType.EXPORT) { export_list_brace = brace_depth; }
            if (arrow_active) { arrow_active = false; }
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            tscan.on_template_head();
        } else if (tt == TokenType.RBRACE) {
            if (tscan.classify_rbrace(self.lexer) == TemplateBrace.BLOCK) {
                if (brace_depth > 0) {
                    if (brace_is_fn[brace_depth]) { cur_fn_depth--; }
                    if (brace_depth == export_list_brace) { export_list_brace = 0; }
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
            decl_exported = prev_tt == TokenType.EXPORT;
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
                destructure_closed = false;
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
            // Binding patterns write their targets through environment
            // operations, desyncing register-allocated globals.
            if (cur < entry) {
                bool pattern_follower = tt == TokenType.ASSIGN || tt == TokenType.IN
                    || (tt == TokenType.IDENTIFIER && tok.str_value == "of");
                if (!destructure_closed) {
                    destructure_closed = true;
                } else {
                    // Only a pattern is followed by `=` (an assignment or a
                    // declaration initializer) or by `in`/`of` (a for head);
                    // any other follower means the candidate was a literal.
                    if (pattern_follower) { disabled = true; break; }
                    in_destructure = false;
                }
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
                if (decl_exported) { exported[idx] = true; }
            } else if (export_list_brace != 0) {
                if (idx < 0) {
                    idx = slot_global_intern(&names[0], &name_lens[0], &count, nm);
                    if (idx < 0) { overflow = true; break; }
                }
                exported[idx] = true;
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

        // An assignment inside parentheses may turn out to be an arrow
        // parameter default, which runs in the arrow's own scope: hold it
        // until the closing paren shows whether `=>` follows.
        if (slot_global_is_assign_op(tt) && prev_tt == TokenType.IDENTIFIER && prev_ident_len > 0) {
            int aidx = slot_global_find(&names[0], &name_lens[0], count,
                                        prev_ident[:prev_ident_len]);
            if (aidx >= 0) {
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

    self.restore_lhs_snapshot(snap);

    if (disabled || overflow || count == 0) return;

    for (uint i = 0; i < count; i++) {
        if (declared[i] && !nested_ref[i] && !exported[i]) {
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

