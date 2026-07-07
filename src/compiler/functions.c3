module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
import std::io;

// ============================================================================
// Function compilation
// ============================================================================

/// Maximum number of bindings collected from destructuring function parameters.
const uint MAX_DESTRUCT_BINDS = 64;

/// Collected info for a single destructured binding from a function parameter.
struct DestructBind {
    uint name_idx;       // constant index of the binding name (0xFFFFFFFF for synthetic)
    uint key_idx;        // constant index of the property key (for object patterns)
    char[64] name_buf;   // binding name string buffer (for declare_var)
    ushort name_len;     // length of the binding name
    ushort arg_idx;      // which formal parameter index this belongs to
    ushort index;        // for array patterns: the element index
    bool is_object;      // true = object pattern, false = array pattern
    bool has_default;    // has a default value expression
    bool is_synthetic;   // true = intermediate extraction point (not a user variable)
    uint   default_func_idx;  // index into inner_funcs for default thunk (0xFFFFFFFF if none)
    ushort parent_idx;     // index of the binding whose value is the source for this one (0xFFFF = direct from arg)
}

/// Check if a candidate param name already exists in the seen-params table.
/// Used for ES5 §13.1 strict-mode duplicate-parameter rejection (strict-only
/// engine: always rejects).
fn bool check_dup_param(char[] name, char[64][] seen, ushort[] seen_lens, uint count) {
    for (uint i = 0; i < count; i++) {
        if (seen_lens[i] == name.len) {
            bool match = true;
            for (usz j = 0; j < name.len; j++) {
                if (seen[i][j] != name[j]) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
    }
    return false;
}

/// Parse an object destructuring pattern within a function parameter list.
/// The '{' token has already been consumed.
/// Collects all leaf-level binding names into the provided arrays.
fn void? CompilerContext.collect_obj_param_binds(&self,
    DestructBind[] binds, uint* count, ushort src_reg, ushort parent_idx)
{
    if (self.match(TokenType.RBRACE)) return;  // empty pattern {}

    for (;;) {
        if (self.check(TokenType.RBRACE)) break;

        // Track whether the last parsed element was a nested pattern (synthetic)
        // so that a following `= default` applies to the synthetic, not a leaf.
        ushort outer_synth_idx = 0xFFFF;
        bool last_was_synth = false;

        // Rest element: {...rest}
        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(rest_tok.str_value)) {
                return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[*count].key_idx = 0xFFFF;
                binds[*count].is_object = true;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(rest_tok.str_value.len < 63 ? rest_tok.str_value.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = rest_tok.str_value[j]; }
                (*count)++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Property name
        Token prop = self.expect(TokenType.IDENTIFIER)!;
        uint prop_key_idx = self.add_string_constant(prop.str_value);

        if (self.match(TokenType.COLON)) {
            // {source: target} — target can be identifier or nested pattern
            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                // Create a synthetic binding for the intermediate extraction
                // e.g. {a: {x,y}} → synthetic for "a" extracts the nested object
                bool is_obj = self.check(TokenType.LBRACE);
                if (*count < binds.len) {
                    binds[*count].key_idx = prop_key_idx;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    binds[*count].is_synthetic = true;
                    (*count)++;
                }
                ushort synth_idx = (ushort)(*count - 1);
                outer_synth_idx = synth_idx;
                last_was_synth = true;
                self.advance()!; // consume '{' or '['
                if (is_obj) {
                    self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
                }
            } else {
                Token bind = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind.str_value)) {
                    return COMPILE_ERROR~;
                }
                if (*count < binds.len) {
                    binds[*count].name_idx = self.add_string_constant(bind.str_value);
                    binds[*count].key_idx = prop_key_idx;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    ushort nl = (ushort)(bind.str_value.len < 63 ? bind.str_value.len : 63);
                    binds[*count].name_len = nl;
                    for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = bind.str_value[j]; }
                    (*count)++;
                }
            }
        } else {
            // Shorthand: {a} — direct child of this destructuring param
            if (*count < binds.len) {
                binds[*count].name_idx = prop_key_idx;
                binds[*count].key_idx = prop_key_idx;
                binds[*count].is_object = true;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(prop.str_value.len < 63 ? prop.str_value.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = prop.str_value[j]; }
                (*count)++;
            }
        }

        // Default: {a = expr} or {a: pattern = expr} — compile as a thunk
        // function like regular defaults. When the previous element was a
        // nested pattern, the default belongs to the synthetic binding.
        if (self.match(TokenType.ASSIGN)) {
            if (*count > 0) {
                ushort target_idx = last_was_synth ? outer_synth_idx : (ushort)(*count - 1);
                binds[target_idx].has_default = true;
                CompiledFunction* default_func = self.compile_default_expr()!;
                uint def_idx = self.add_inner_func(default_func);
                binds[target_idx].default_func_idx = def_idx;
            }
        }

        if (!self.match(TokenType.COMMA)) break;
        if (self.check(TokenType.RBRACE)) break;
    }

    self.expect(TokenType.RBRACE)!;
    return;
}

/// Parse an array destructuring pattern within a function parameter list.
/// The '[' token has already been consumed.
/// Collects all leaf-level binding names into the provided arrays.
fn void? CompilerContext.collect_arr_param_binds(&self,
    DestructBind[] binds, uint* count, ushort src_reg, ushort parent_idx)
{
    ushort elem_idx = 0;

    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        // Track whether the last parsed element was a nested pattern (synthetic)
        // so that a following `= default` applies to the synthetic, not a leaf.
        ushort outer_synth_idx = 0xFFFF;
        bool last_was_synth = false;

        if (self.match(TokenType.COMMA)) {
            elem_idx++;
            continue;
        }

        // Rest element: [...rest] or {...rest}
        if (self.match(TokenType.ELLIPSIS)) {
            // Nested rest pattern: create a synthetic for the rest then recurse
            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                bool is_obj = self.check(TokenType.LBRACE);
                if (*count < binds.len) {
                    binds[*count].key_idx = 0xFFFF;
                    binds[*count].index = elem_idx;
                    binds[*count].is_object = false;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    binds[*count].is_synthetic = true;
                    (*count)++;
                }
                ushort synth_idx = (ushort)(*count - 1);
                outer_synth_idx = synth_idx;
                last_was_synth = true;
                self.advance()!;
                if (is_obj) {
                    self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
                }
            } else {
                Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(rest_tok.str_value)) {
                    return COMPILE_ERROR~;
                }
                if (*count < binds.len) {
                    binds[*count].name_idx = self.add_string_constant(rest_tok.str_value);
                    binds[*count].key_idx = 0xFFFF;
                    binds[*count].index = elem_idx;
                    binds[*count].is_object = false;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    ushort nl = (ushort)(rest_tok.str_value.len < 63 ? rest_tok.str_value.len : 63);
                    binds[*count].name_len = nl;
                    for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = rest_tok.str_value[j]; }
                    (*count)++;
                }
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Nested pattern: create a synthetic binding for the intermediate extraction
        if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
            bool is_obj = self.check(TokenType.LBRACE);
            if (*count < binds.len) {
                binds[*count].key_idx = 0;
                binds[*count].index = elem_idx;
                binds[*count].is_object = false;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                binds[*count].is_synthetic = true;
                (*count)++;
            }
            ushort synth_idx = (ushort)(*count - 1);
            outer_synth_idx = synth_idx;
            last_was_synth = true;
            self.advance()!;
            if (is_obj) {
                self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
            } else {
                self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
            }
        } else {
            Token bind = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(bind.str_value)) {
                return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx = self.add_string_constant(bind.str_value);
                binds[*count].key_idx = 0;  // use index instead
                binds[*count].index = elem_idx;
                binds[*count].is_object = false;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(bind.str_value.len < 63 ? bind.str_value.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = bind.str_value[j]; }
                (*count)++;
            }
        }

        // Default: [a = expr] or [pattern = expr] — compile as a thunk
        // function like regular defaults. When the previous element was a
        // nested pattern, the default belongs to the synthetic binding.
        if (self.match(TokenType.ASSIGN)) {
            if (*count > 0) {
                ushort target_idx = last_was_synth ? outer_synth_idx : (ushort)(*count - 1);
                binds[target_idx].has_default = true;
                CompiledFunction* default_func = self.compile_default_expr()!;
                uint def_idx = self.add_inner_func(default_func);
                binds[target_idx].default_func_idx = def_idx;
            }
        }

        elem_idx++;

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;
    return;
}

/// Skip past a braced block in the lexer without compiling.
/// Assumes the lexer is positioned just after '{'. Advances past matching '}'.
fn void CompilerContext.skip_braced_block(&self) {
    uint brace_depth = 1;
    while (brace_depth > 0) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) break;
        if (tt == TokenType.LBRACE) { brace_depth++; }
        else if (tt == TokenType.RBRACE) { brace_depth--; }
    }
}

/// Skip past a full function declaration body starting from '('.
/// Consumes '(' params ')' '{' body '}'.
fn void CompilerContext.skip_function_body(&self) {
    // Skip '(' ... ')'
    uint paren_depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LPAREN) { paren_depth++; }
        else if (tt == TokenType.RPAREN) {
            paren_depth--;
            if (paren_depth == 0) break; // found the matching ')'
        }
    }
    // Skip '{' ... '}'
    // The next token should be '{'. Skip until the matching '}'.
    uint brace_depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LBRACE) { brace_depth++; }
        else if (tt == TokenType.RBRACE) {
            brace_depth--;
            if (brace_depth == 0) break; // found matching '}'
        }
    }
}

/// Skip past a single destructuring pattern (`{...}` or `[...]`), handling
/// arbitrarily nested `{}`/`[]` of either kind. The opening token has
/// already been consumed by the caller; this advances the lexer to just
/// past the matching closing token.
fn void CompilerContext.skip_destructure_pattern(&self) {
    int depth = 1;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LBRACE || tt == TokenType.LBRACKET) {
            depth++;
        } else if (tt == TokenType.RBRACE || tt == TokenType.RBRACKET) {
            depth--;
            if (depth == 0) return;
        }
    }
}

/// Scan forward through a destructured parameter pattern from the current
/// lexer position to find the matching closing ')' and check if '=>' follows.
/// Returns true if this is an arrow function with destructured params.
/// Assumes the outer '(' has already been consumed and the lexer is positioned
/// at the start of the destructuring pattern ({ or [).
fn bool CompilerContext.scan_destruct_param_to_arrow(&self) {
    int paren_d = 1;   // outer '(' already consumed
    int brace_d = 0;
    int bracket_d = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) { break; }
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) { break; }
        if (tt == TokenType.LPAREN) { paren_d++; }
        else if (tt == TokenType.RPAREN) {
            paren_d--;
            if (paren_d == 0) {
                return self.check(TokenType.ARROW);
            }
        }
        else if (tt == TokenType.LBRACE) { brace_d++; }
        else if (tt == TokenType.RBRACE) { brace_d--; }
        else if (tt == TokenType.LBRACKET) { bracket_d++; }
        else if (tt == TokenType.RBRACKET) { bracket_d--; }
    }
    return false;
}

/// Skip past an arbitrary expression in the lexer without compiling.
/// Tracks paren, brace, and bracket depth.
fn void CompilerContext.skip_expression(&self) {
    uint paren_depth = 0;
    uint brace_depth = 0;
    uint bracket_depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) break;
        if (tt == TokenType.LPAREN) { paren_depth++; }
        else if (tt == TokenType.RPAREN) {
            if (paren_depth == 0 && brace_depth == 0 && bracket_depth == 0) {
                // This closing paren belongs to the caller — push back
                self.lexer.pushback(tok_opt);
                break;
            }
            if (paren_depth > 0) paren_depth--;
        }
        else if (tt == TokenType.LBRACE) { brace_depth++; }
        else if (tt == TokenType.RBRACE) {
            if (brace_depth == 0 && bracket_depth == 0 && paren_depth == 0) break;
            if (brace_depth > 0) brace_depth--;
        }
        else if (tt == TokenType.LBRACKET) { bracket_depth++; }
        else if (tt == TokenType.RBRACKET) {
            if (bracket_depth > 0) bracket_depth--;
        }
        else if (paren_depth == 0 && brace_depth == 0 && bracket_depth == 0) {
            // At top level: break on comma, semicolon, EOF
            if (tt == TokenType.COMMA || tt == TokenType.SEMICOLON) {
                self.lexer.pushback(tok_opt);
                break;
            }
        }
    }
}

/// Pre-scan function body for var and function declarations and emit hoisted
/// bytecode so they are available before any statements run.
fn void? CompilerContext.hoist_decls(&self, bool is_global) {
    // --- Save lexer state (for final restore) ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    uint brace_depth = 0;

    while (true) {
        // Save lexer state before consuming this token (so we can restore
        // and re-consume it for function compilation).
        uint pos_before = self.lexer.pos;
        uint line_before = self.lexer.line;
        uint col_before = self.lexer.col;
        Token cur_before = self.lexer.current;
        Token look_before = self.lexer.lookahead;
        bool haslk_before = self.lexer.has_lookahead;
        Token push_before = self.lexer.pushed_back;
        bool haspb_before = self.lexer.has_pushed_back;
        bool slt_before = self.lexer.seen_line_term;

        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }
        if (tt == TokenType.RBRACE) {
            if (!is_global && brace_depth == 0) break;
            if (brace_depth > 0) brace_depth--;
            // For function-level hoisting, stop when the function body's
            // closing '}' returns brace_depth to 0 (end of scanned scope).
            if (!is_global && brace_depth == 0) break;
            continue;
        }

        // Detect `async function` at brace_depth 0: the pre-scan sees
        // IDENTIFIER("async") first, peeks at FUNCTION, and if so pushes
        // "function" back so the next iteration handles it as a FUNCTION
        // token with is_async already set.
        if (brace_depth == 0 && tt == TokenType.IDENTIFIER &&
            tok_opt.str_value.len == 5 &&
            tok_opt.str_value[0] == 'a' && tok_opt.str_value[1] == 's' &&
            tok_opt.str_value[2] == 'y' && tok_opt.str_value[3] == 'n' &&
            tok_opt.str_value[4] == 'c') {
            Token? async_peek = self.lexer.next_token();
            if (catch _err_peek = async_peek) continue;
            if (async_peek.type == TokenType.FUNCTION) {
                // "async" consumed; push "function" back for the next iteration.
                {
                    Token fn_tok = async_peek;
                    self.lexer.pushback(fn_tok);
                }
                self.is_async = true;
                continue;
            }
            // Not followed by function — push back the peeked token
            {
                Token async_tok = async_peek;
                self.lexer.pushback(async_tok);
            }
        }

        if (brace_depth == 0 && tt == TokenType.FUNCTION) {
            // At global/module scope, function declarations are already hoisted
            // by hoist_global_fn_decls().  Skip them here to avoid double
            // compilation — just advance past the star, name, and body.
            if (is_global) {
                self.is_async = false;
                // Consume optional generator star
                Token? skip_star = self.lexer.next_token();
                if (catch _err_skip = skip_star) continue;
                if (skip_star.type == TokenType.STAR) {
                    // Star consumed; next token is the name
                } else {
                    // Not a star — push back (it's the name)
                    self.lexer.pushback(skip_star);
                }
                // Consume function name
                Token? skip_name = self.lexer.next_token();
                if (catch _err_skip2 = skip_name) continue;
                if (skip_name.type != TokenType.IDENTIFIER) {
                    // Anonymous function expression — push the token back so
                    // skip_function_body sees the full `function (...) { ... }`.
                    // For example in `(function() { ... }())`, the `(` is the
                    // function's param-open; we must leave it for the skipper.
                    self.lexer.pushback(skip_name);
                }
                // skip_function_body expects lexer past the name — skip (params) { body }
                self.skip_function_body();
                continue;
            }
            // If we detected `async function` above, is_async is already true.
            bool hoist_is_async = self.is_async;
            self.is_async = false;
            // Check for generator star
            Token? star_opt = self.lexer.next_token();
            if (catch _err2 = star_opt) continue;
            if (star_opt.type != TokenType.STAR) {
                // Not a star — put it back (it's the function name)
                self.lexer.pushback(star_opt);
            }
            Token? name_opt = self.lexer.next_token();
            if (catch _err = name_opt) break;
            if (name_opt.type != TokenType.IDENTIFIER) continue;

            char[] fn_name = name_opt.str_value;
            if (fn_name.len == 0) continue;

            // Check if already hoisted
            bool already = false;
            for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                // Skip the rest of the function body
                self.skip_function_body();
                continue;
            }

            // Record as hoisted
            if (self.hoisted_fn_count < 256) {
                self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
                self.hoisted_fn_count++;
            }

            // Restore lexer to before 'function' so we can re-consume it properly
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;

            // Re-consume 'function' (async was already consumed before restore)
            self.expect(TokenType.FUNCTION)!;
            // Byte offset of `function` keyword for Function.prototype.toString
            // source-text retention.
            uint hoist_fn1_src_start = self.lexer.token_start;

            // Handle generator star
            bool saved_gen = self.is_generator;
            self.is_generator = false;
            if (self.match(TokenType.STAR)) {
                self.is_generator = true;
            }

            Token name_tok2 = self.expect(TokenType.IDENTIFIER)!;

            ushort func_reg = self.declare_var(name_tok2.str_value, VAR);
            self.has_local_bindings = true;

            // Regular function declarations are constructable per ES2015 §14.1.2 —
            // save/restore the flag around the inner compile so nested functions
            // inherit it. Generator functions are never constructable (§14.4) —
            // `new` on one must throw TypeError.
            bool saved_is_constructable = self.is_constructable;
            self.is_constructable = !self.is_generator;

            self.is_async = hoist_is_async;
            // Use the byte offset of `function` captured right after expect().
            CompiledFunction* inner = self.compile_inner_function(name_tok2.str_value, false, hoist_fn1_src_start)!;
            self.is_async = false;

            self.is_generator = saved_gen;
            self.is_constructable = saved_is_constructable;

            uint inner_idx = self.add_inner_func(inner);

            // Emit CLOSURE + DECLVAR
            self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
            uint name_idx = self.add_string_constant(name_tok2.str_value);
            self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);

            // Lexer is now past the function body. Continue scanning.
        } else if (tt == TokenType.VAR) {
            // var declarations hoisted to function scope.  At global/module
            // scope, only top-level (brace_depth == 0) vars need hoisting;
            // vars inside function bodies are hoisted by their own scope.
            if (is_global && brace_depth > 0) continue;
            for (;;) {
                Token? name_opt2 = self.lexer.next_token();
                if (catch _err = name_opt2) break;
                Token name_tok2 = name_opt2;
                if (name_tok2.type != TokenType.IDENTIFIER) break;

                ushort var_reg = self.declare_var(name_tok2.str_value, VAR);
                self.has_local_bindings = true;
                self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
                uint var_name_idx = self.add_string_constant(name_tok2.str_value);
                self.emit_a_bc(Opcode.DECLVAR, (uint)var_reg, var_name_idx);

                // Check for initializer or comma
                Token? sep_opt = self.lexer.next_token();
                if (catch _err = sep_opt) break;
                TokenType sep = sep_opt.type;
                if (sep == TokenType.ASSIGN) {
                    self.skip_expression();
                } else if (sep != TokenType.COMMA) {
                    break;
                }
            }
        } else if (!is_global && brace_depth == 0) {
            // Top-level token that isn't a declaration (function/var) — the
            // remaining program is real code (statements). Restore the lexer
            // to before this token and stop pre-scanning; the main statement()
            // loop will parse it.
            // Only applied for function-level hoisting (is_global=false).
            // Global hoisting must scan the entire source for interspersed declarations.
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;
            break;
        }
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;
}

/// Pre-scan function declarations at the top level (global scope) and hoist them
/// before any statements are compiled. This implements function declaration
/// hoisting as per ES5 §10.2.1.1.
fn void? CompilerContext.hoist_global_fn_decls(&self) {
    // --- Save lexer state (for final restore) ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    uint brace_depth = 0;

    // Track the previous top-level token to disambiguate
    // function declarations from function expressions in expressions like
    // `var x = function name() { ... }`.  A `function` keyword at
    // brace_depth 0 is a declaration only when preceded by a statement
    // terminator (`;`, `{`, `}`, or start-of-file).  After an operator
    // (`=`, `(`, `,`, `:`, `?`, etc.) the `function` is an expression
    // and must be skipped.
    TokenType prev_toplevel = TokenType.EOF_TOKEN;
    bool has_prev = false;

    while (true) {
        // Save lexer state before consuming this token (so we can restore
        // and re-consume it for function compilation).
        uint pos_before = self.lexer.pos;
        uint line_before = self.lexer.line;
        uint col_before = self.lexer.col;
        Token cur_before = self.lexer.current;
        Token look_before = self.lexer.lookahead;
        bool haslk_before = self.lexer.has_lookahead;
        Token push_before = self.lexer.pushed_back;
        bool haspb_before = self.lexer.has_pushed_back;
        bool slt_before = self.lexer.seen_line_term;

        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }
        if (tt == TokenType.RBRACE) {
            brace_depth--;
            if (brace_depth == 0) {
                prev_toplevel = TokenType.RBRACE;
                has_prev = true;
            }
            continue;
        }

        // Detect `async function` at brace_depth 0
        if (brace_depth == 0 && tt == TokenType.IDENTIFIER &&
            tok_opt.str_value.len == 5 &&
            tok_opt.str_value[0] == 'a' && tok_opt.str_value[1] == 's' &&
            tok_opt.str_value[2] == 'y' && tok_opt.str_value[3] == 'n' &&
            tok_opt.str_value[4] == 'c') {
            Token? async_peek = self.lexer.next_token();
            if (catch _err_peek = async_peek) continue;
            if (async_peek.type == TokenType.FUNCTION) {
                {
                    Token fn_tok = async_peek;
                    self.lexer.pushback(fn_tok);
                }
                self.is_async = true;
                continue;
            }
            {
                Token async_tok = async_peek;
                self.lexer.pushback(async_tok);
            }
        }

        if (brace_depth == 0 && tt == TokenType.SEMICOLON) {
            prev_toplevel = TokenType.SEMICOLON;
            has_prev = true;
            continue;
        }

        if (brace_depth == 0 && tt == TokenType.FUNCTION) {
            // `function` at brace_depth 0 is a declaration only when it
            // starts a statement.  In expression position (after `=`,
            // `(`, `,`, `:`, `?`, `=>`, etc.) it must be skipped to
            // avoid double-compilation by the statement parser.
            bool in_stmt_pos = !has_prev
                || prev_toplevel == TokenType.SEMICOLON
                || prev_toplevel == TokenType.RBRACE
                || prev_toplevel == TokenType.LBRACE
                || prev_toplevel == TokenType.EOF_TOKEN;
            if (!in_stmt_pos) {
                // Expression position — skip the entire function expression
                // body so we don't compile it here.  The statement parser
                // will see the `function` token on the second pass.
                self.skip_function_body();
                prev_toplevel = TokenType.FUNCTION;
                has_prev = true;
                continue;
            }
            bool hoist_is_async = self.is_async;
            self.is_async = false;
            // Check for generator star
            Token? star_opt = self.lexer.next_token();
            if (catch _err2 = star_opt) continue;
            if (star_opt.type != TokenType.STAR) {
                // Not a star — put it back (it's the function name)
                self.lexer.pushback(star_opt);
            }
            Token? name_opt = self.lexer.next_token();
            if (catch _err = name_opt) break;
            if (name_opt.type != TokenType.IDENTIFIER) continue;

            char[] fn_name = name_opt.str_value;
            if (fn_name.len == 0) continue;

            // Check if already hoisted
            bool already = false;
            for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                // Skip the rest of the function body
                self.skip_function_body();
                continue;
            }

            // Record as hoisted
            if (self.hoisted_fn_count < 256) {
                self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
                self.hoisted_fn_count++;
            }

            // Restore lexer to before 'function' so we can re-consume it properly
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;

            // Re-consume 'function' (async was already consumed before restore)
            self.expect(TokenType.FUNCTION)!;
            // Byte offset of `function` keyword for Function.prototype.toString
            // source-text retention.
            uint hoist_fn1_src_start = self.lexer.token_start;

            // Handle generator star
            bool saved_gen = self.is_generator;
            self.is_generator = false;
            if (self.match(TokenType.STAR)) {
                self.is_generator = true;
            }

            Token name_tok2 = self.expect(TokenType.IDENTIFIER)!;

            ushort func_reg = self.declare_var(name_tok2.str_value, VAR);
            self.has_local_bindings = true;

            // Regular function declarations are constructable per ES2015 §14.1.2 —
            // save/restore the flag around the inner compile so nested functions
            // inherit it. Generator functions are never constructable (§14.4) —
            // `new` on one must throw TypeError.
            bool saved_is_constructable = self.is_constructable;
            self.is_constructable = !self.is_generator;

            self.is_async = hoist_is_async;
            // Use the byte offset of `function` captured right after expect().
            CompiledFunction* inner = self.compile_inner_function(name_tok2.str_value, false, hoist_fn1_src_start)!;
            self.is_async = false;

            self.is_generator = saved_gen;
            self.is_constructable = saved_is_constructable;

            uint inner_idx = self.add_inner_func(inner);

            // Emit CLOSURE + DECLVAR
            self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
            uint name_idx = self.add_string_constant(name_tok2.str_value);
            self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);

            // Lexer is now past the function body. Continue scanning.
            prev_toplevel = TokenType.FUNCTION;
            has_prev = true;
            continue;
        }

        // For other top-level tokens, record the operator so the next
        // `function` (if any) is recognized as an expression.  Any token
        // that is not a statement terminator (`;`, `{`, `}`) puts the
        // following `function` in expression position.
        if (brace_depth == 0 && tt != TokenType.SEMICOLON
            && tt != TokenType.LBRACE && tt != TokenType.RBRACE
            && tt != TokenType.EOF_TOKEN) {
            prev_toplevel = tt;
            has_prev = true;
        }
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;
}

/// Parse function body (parameters and block) and compile into a nested context.
fn void? CompilerContext.parse_function_body(&self, bool is_expr) {
    // Parse parameter list
    self.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Track seen param names for duplicate-param rejection (strict mode ES5 §13.1,
    // strict-only engine). Each entry stores name bytes; comparison is byte-wise.
    char[64][MAX_PARAMS] seen_param_names;
    ushort[MAX_PARAMS]    seen_param_lens;
    uint seen_param_count = 0;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] destruct_binds;
    uint destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] destruct_group_regs;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...[]
                if (self.check(TokenType.LBRACE)) {
                    self.advance()!;
                    self.alloc_reg();
                    self.collect_obj_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {}; // mark as destructured
                } else if (self.check(TokenType.LBRACKET)) {
                    self.advance()!;
                    self.alloc_reg();
                    self.collect_arr_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = self.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    if (is_restricted_name(rest_param.str_value)) {
                        return COMPILE_ERROR~;
                    }
                    if (check_dup_param(rest_param.str_value, seen_param_names[..], seen_param_lens[..], seen_param_count)) {
                        return COMPILE_ERROR~;
                    }
                    if (seen_param_count < MAX_PARAMS && rest_param.str_value.len < 64) {
                        for (usz k = 0; k < rest_param.str_value.len; k++) {
                            seen_param_names[seen_param_count][k] = rest_param.str_value[k];
                        }
                        seen_param_lens[seen_param_count] = (ushort)rest_param.str_value.len;
                        seen_param_count++;
                    }
                    ushort rest_reg = self.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = self.add_string_constant(rest_param.str_value);
                    self.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                self.has_rest = true;
                self.rest_formal_count = arg_count - 1;
                self.num_args = arg_count;
                self.formal_count = formal_count;
                // Rest parameter must be last
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (self.check(TokenType.LBRACE)) {
                self.advance()!;
                // Reserve the formal parameter register slot so the incoming
                // argument stays live through all destructuring extractions.
                self.alloc_reg();
                // Emit REQUIRE_OBJ to throw TypeError if null/undefined.
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                self.collect_obj_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RPAREN)) break;
                continue;
            } else if (self.check(TokenType.LBRACKET)) {
                self.advance()!;
                // Reserve the formal parameter register slot.
                self.alloc_reg();
                // Emit REQUIRE_OBJ to throw TypeError if null/undefined.
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                self.collect_arr_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            if (check_dup_param(param.str_value, seen_param_names[..], seen_param_lens[..], seen_param_count)) {
                return COMPILE_ERROR~;
            }
            if (seen_param_count < MAX_PARAMS && param.str_value.len < 64) {
                for (usz k = 0; k < param.str_value.len; k++) {
                    seen_param_names[seen_param_count][k] = param.str_value[k];
                }
                seen_param_lens[seen_param_count] = (ushort)param.str_value.len;
                seen_param_count++;
            }
            ushort param_reg = self.declare_var(param.str_value, VAR);
            uint param_name_idx = self.add_string_constant(param.str_value);
            arg_count++;

            // Check for default value
            if (self.check(TokenType.ASSIGN)) {
                self.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = self.compile_default_expr()!;

                // Add to inner functions table
                if (self.default_count < MAX_PARAMS) {
                    uint def_idx = self.add_inner_func(default_func);
                    self.defaults[self.default_count].param_reg = param_reg;
                    self.defaults[self.default_count].param_name_idx = param_name_idx;
                    self.defaults[self.default_count].default_func_idx = def_idx;
                    self.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            // Only increment formal_count if no default has been seen yet.
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // DECLVAR creates binding in var_env.
            self.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!self.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (self.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!self.has_rest) {
        self.num_args = arg_count;
    }
    self.formal_count = formal_count;

    self.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables.
    // Synthetics don't get variables — they're intermediate extraction points.
    for (uint i = 0; i < destruct_count; i++) {
        if (destruct_binds[i].is_synthetic) {
            destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = destruct_binds[i].name_idx;
        char[] name = destruct_binds[i].name_buf[:destruct_binds[i].name_len];
        ushort dreg = self.declare_var(name, VAR);
        destruct_binding_regs[i] = dreg;
        self.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }


    // Push a function-level lexical scope for let/const at function top level.
    // This sits above the block-level PUSH_LEX emitted by block() so that
    // function-level let/const go into a scope that outlives inner blocks.
    // Skip when there are no default parameters (the only case that needs
    // a function-level scope distinct from the block scope).
    bool has_func_lex = self.default_count > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            self.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            self.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < self.default_count; di++) {
        ushort pr = self.defaults[di].param_reg;
        uint name_idx = self.defaults[di].param_name_idx;
        uint func_idx = self.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = self.code_count;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        self.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = self.alloc_reg();
        if (self.next_reg <= call_base + 1) {
            self.next_reg = call_base + 2;
        }
        ushort this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Copy default result to parameter register.
        self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        self.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        // This ensures PUTVAR runs for BOTH branches (argument passed or default used).
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to lex scope first (clears TDZ sentinel), then var_env.
        // GETVAR reloads from env in case PUTVAR cleared it.
        self.emit_a_bc(Opcode.PUTLEX, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < self.default_count; di++) {
                if (self.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                self.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit destructuring code for destructured function parameters.
    // Walk bindings in declaration order:
    //   Synthetics: GETPROP from parent's source → group_reg, REQUIRE_OBJ
    //   Leaves:     GETPROP from parent's group_reg (or arg) → bind_reg
    if (destruct_count > 0) {
        for (uint di = 0; di < destruct_count; di++) {
            // Resolve source register — either the argument slot or a parent group temp
            ushort src_reg;
            if (destruct_binds[di].parent_idx == 0xFFFF) {
                src_reg = destruct_binds[di].arg_idx;
            } else {
                src_reg = destruct_group_regs[destruct_binds[di].parent_idx];
            }

            if (destruct_binds[di].is_synthetic) {
                // Allocate a temp register for this intermediate extraction
                ushort group_reg = self.alloc_reg();
                destruct_group_regs[di] = group_reg;

                // GETPROP/LDREG source → group_reg
                if (destruct_binds[di].is_object) {
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, destruct_binds[di].key_idx);
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                } else {
                    ushort key_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)destruct_binds[di].index));
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                }

                // Default value check for nested patterns: if group_reg is
                // undefined, evaluate the default thunk before REQUIRE_OBJ.
                if (destruct_binds[di].has_default) {
                    ushort undef_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = self.alloc_reg();
                    self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)group_reg, (uint)undef_reg);
                    self.free_reg(undef_reg);

                    uint skip_addr = self.code_count;
                    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    self.free_reg(cmp_reg);

                    ushort closure_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, destruct_binds[di].default_func_idx);

                    ushort call_base = self.alloc_reg();
                    if (self.next_reg <= call_base + 1) { self.next_reg = call_base + 2; }
                    self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    self.emit_abc(Opcode.LDREG, (uint)group_reg, (uint)call_base, 0);
                    self.free_regs_to(call_base);

                    int skip_off = (int)self.code_count - (int)skip_addr - 1;
                    self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                // REQUIRE_OBJ — TypeError if null/undefined nested target
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            } else {
                // Leaf binding — a real variable
                ushort bind_reg = destruct_binding_regs[di];
                uint ni = destruct_binds[di].name_idx;

                // GETPROP/LDREG source → bind_reg
                if (destruct_binds[di].is_object) {
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, destruct_binds[di].key_idx);
                    self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                } else {
                    if (destruct_binds[di].key_idx == 0xFFFF) {
                        self.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)src_reg, 0);
                    } else {
                        ushort key_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)destruct_binds[di].index));
                        self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                        self.free_reg(key_reg);
                    }
                }

                // Default value check: if bind_reg is undefined, use the default thunk
                if (destruct_binds[di].has_default) {
                    ushort undef_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = self.alloc_reg();
                    self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)bind_reg, (uint)undef_reg);
                    self.free_reg(undef_reg);

                    uint skip_addr = self.code_count;
                    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    self.free_reg(cmp_reg);

                    ushort closure_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, destruct_binds[di].default_func_idx);

                    ushort call_base = self.alloc_reg();
                    if (self.next_reg <= call_base + 1) { self.next_reg = call_base + 2; }
                    self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    self.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)call_base, 0);
                    self.free_regs_to(call_base);

                    int skip_off = (int)self.code_count - (int)skip_addr - 1;
                    self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                // Sync binding to environment
                self.emit_a_bc(Opcode.PUTVAR, (uint)bind_reg, ni);
                self.emit_a_bc(Opcode.GETVAR, (uint)bind_reg, ni);
            }
        }
    }

    // Hoist var and function declarations to the top of the function scope.
    self.hoist_decls(false)!;

    // Compile function body block
    self.block(true)!;

    // Pop the function-level lexical scope.
    // NOTE: for functions with explicit return, this POP_LEX won't execute,
    // but that's harmless — the activation is destroyed on return.
    if (has_func_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    // Emit implicit return undefined if no explicit return
    // Check if last instruction is a return
    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        self.emit_simple((self.is_generator && !self.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }
}

/// Compile a default parameter expression as a zero-argument inner function.
/// Free variables in the expression are resolved at runtime via GETVAR
/// against the outer scope's environment chain.
fn CompiledFunction*? CompilerContext.compile_default_expr(&self) {
    // Create a new CompilerContext for the default expression
    CompilerContext def_ctx;
    def_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    def_ctx.lexer.set_strict(true);

    // Propagate class context (for super expressions)
    def_ctx.in_class_body = self.in_class_body;
    def_ctx.has_super_binding = self.has_super_binding;

    // Function-level lexical scope (empty — no parameters)
    def_ctx.emit_simple(Opcode.PUSH_LEX);

    // Compile expression with implicit return
    ushort expr_reg = def_ctx.assignment_expr()!;
    def_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);

    // Pop the function-level lexical scope
    def_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = def_ctx.finish()!;

    // If the default expression references 'arguments', clear the thunk's
    // flag (prevent VM from creating a thunk-specific arguments object that
    // shadows the parent's) and propagate to the enclosing function so the
    // VM creates the parent's arguments object.
    if (def_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        self.uses_arguments = true;
    }

    // Default thunks need their parent's lex scope bridged into the
    // activation so TDZ sentinels for params are visible via GETVAR.
    func.flags.needs_lex_bridge = true;

    return func;
}

/// Compile a computed property key expression into a 0-arg inner function.
/// The caller must have already consumed the `[` token.
/// This function compiles the expression and `]` is consumed by the caller after.
fn CompiledFunction*? CompilerContext.compile_key_expr(&self) {
    CompilerContext key_ctx;
    key_ctx.init(self.lexer, self.heap);
    key_ctx.lexer.set_strict(true);
    key_ctx.in_class_body = self.in_class_body;
    key_ctx.has_super_binding = self.has_super_binding;

    key_ctx.emit_simple(Opcode.PUSH_LEX);
    ushort expr_reg = key_ctx.assignment_expr()!;
    key_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    key_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = key_ctx.finish()!;
    return func;
}

/// Compile an inner function (parameters + body) into a sub-CompiledFunction.
/// If `is_named_expr` is true and `name` is non-empty, the resulting function
/// is tagged with `is_namebinding`, signalling the VM to bind `name` to the
/// function object in a fresh lexical environment at call time (per ES2015
/// §14.1.20 NamedEvaluation).
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name, bool is_named_expr = false, uint src_start = 0xFFFFFFFF) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict, no propagation needed
    inner_ctx.lexer.set_strict(true);

    // Propagate generator flag: if the caller is compiling a generator,
    // the inner context (which parses the body) needs to know it's in a generator.
    inner_ctx.is_generator = self.is_generator;

    // Propagate async flag: if the caller is compiling an async function,
    // the inner context (which parses the body) needs to know it's in an async function.
    // Async functions also set is_generator so they can use YIELD/LOAD_RESUME
    // for suspend/resume via the AWAIT opcode.
    inner_ctx.is_async = self.is_async;
    if (inner_ctx.is_async) inner_ctx.is_generator = true;

    // Propagate class context (for super expressions)
    inner_ctx.in_class_body = self.in_class_body;
    inner_ctx.has_super_binding = self.has_super_binding;
    // Propagate constructable flag: super() only valid in constructors
    inner_ctx.is_constructable = self.is_constructable;

    // Parse parameter list
    inner_ctx.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Track seen param names for duplicate-param rejection (strict-only engine).
    char[64][MAX_PARAMS] inner_seen_names;
    ushort[MAX_PARAMS]    inner_seen_lens;
    uint inner_seen_count = 0;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] inner_destruct_binds;
    uint inner_destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] inner_destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] inner_destruct_group_regs;

    if (!inner_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (inner_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...{a, b} or ...[a, b]
                if (inner_ctx.check(TokenType.LBRACE)) {
                    inner_ctx.advance()!;
                    inner_ctx.alloc_reg();
                    inner_ctx.collect_obj_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else if (inner_ctx.check(TokenType.LBRACKET)) {
                    inner_ctx.advance()!;
                    inner_ctx.alloc_reg();
                    inner_ctx.collect_arr_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = inner_ctx.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    if (is_restricted_name(rest_param.str_value)) {
                        return COMPILE_ERROR~;
                    }
                    if (check_dup_param(rest_param.str_value, inner_seen_names[..], inner_seen_lens[..], inner_seen_count)) {
                        return COMPILE_ERROR~;
                    }
                    if (inner_seen_count < MAX_PARAMS && rest_param.str_value.len < 64) {
                        for (usz k = 0; k < rest_param.str_value.len; k++) {
                            inner_seen_names[inner_seen_count][k] = rest_param.str_value[k];
                        }
                        inner_seen_lens[inner_seen_count] = (ushort)rest_param.str_value.len;
                        inner_seen_count++;
                    }
                    ushort rest_reg = inner_ctx.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = inner_ctx.add_string_constant(rest_param.str_value);
                    inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                inner_ctx.has_rest = true;
                inner_ctx.rest_formal_count = arg_count - 1;
                inner_ctx.num_args = arg_count;
                inner_ctx.formal_count = formal_count;
                // Rest parameter must be last
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (inner_ctx.check(TokenType.LBRACE)) {
                inner_ctx.advance()!;
                // Reserve the formal parameter register slot so the incoming
                // argument stays live through all destructuring extractions
                // and isn't reused by a later parameter's register allocation.
                inner_ctx.alloc_reg();
                // The destructuring pattern itself must be consumed FIRST
                // (the closing `}` happens before the `= default`), then we
                // check for the outer default. The default check itself is
                // deferred (see emit_destruct_param_defaults) until every
                // parameter's arg slot is known, so its scratch registers
                // can't clobber a later parameter's live argument.
                inner_ctx.collect_obj_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = inner_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    inner_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!inner_ctx.match(TokenType.COMMA)) break;
                if (inner_ctx.check(TokenType.RPAREN)) break;
                continue;
            } else if (inner_ctx.check(TokenType.LBRACKET)) {
                inner_ctx.advance()!;
                // Reserve the formal parameter register slot (see LBRACE above).
                inner_ctx.alloc_reg();
                // Same shape as the LBRACE branch above.
                inner_ctx.collect_arr_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = inner_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    inner_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!inner_ctx.match(TokenType.COMMA)) break;
                if (inner_ctx.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = inner_ctx.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            if (check_dup_param(param.str_value, inner_seen_names[..], inner_seen_lens[..], inner_seen_count)) {
                return COMPILE_ERROR~;
            }
            if (inner_seen_count < MAX_PARAMS && param.str_value.len < 64) {
                for (usz k = 0; k < param.str_value.len; k++) {
                    inner_seen_names[inner_seen_count][k] = param.str_value[k];
                }
                inner_seen_lens[inner_seen_count] = (ushort)param.str_value.len;
                inner_seen_count++;
            }
            ushort param_reg = inner_ctx.declare_var(param.str_value, VAR);
            uint param_name_idx = inner_ctx.add_string_constant(param.str_value);
            arg_count++;
            // DECLVAR creates binding in var_env.
            inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Check for default value
            if (inner_ctx.check(TokenType.ASSIGN)) {
                inner_ctx.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = inner_ctx.compile_default_expr()!;

                // Add to inner functions table
                if (inner_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = inner_ctx.add_inner_func(default_func);
                    inner_ctx.defaults[inner_ctx.default_count].param_reg = param_reg;
                    inner_ctx.defaults[inner_ctx.default_count].param_name_idx = param_name_idx;
                    inner_ctx.defaults[inner_ctx.default_count].default_func_idx = def_idx;
                    inner_ctx.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!inner_ctx.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (inner_ctx.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!inner_ctx.has_rest) {
        inner_ctx.num_args = arg_count;
    }
    inner_ctx.formal_count = formal_count;

    inner_ctx.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables (skip synthetics).
    for (uint i = 0; i < inner_destruct_count; i++) {
        if (inner_destruct_binds[i].is_synthetic) {
            inner_destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = inner_destruct_binds[i].name_idx;
        char[] bind_name = inner_destruct_binds[i].name_buf[:inner_destruct_binds[i].name_len];
        ushort dreg = inner_ctx.declare_var(bind_name, VAR);
        inner_destruct_binding_regs[i] = dreg;
        inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }

    // Push a function-level lexical scope for let/const at function top level.
    // Skip when there are no default parameters.
    bool inner_has_func_lex = inner_ctx.default_count > 0;
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            inner_ctx.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            inner_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < inner_ctx.default_count; di++) {
        ushort pr = inner_ctx.defaults[di].param_reg;
        uint name_idx = inner_ctx.defaults[di].param_name_idx;
        uint func_idx = inner_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        inner_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = inner_ctx.code_count;
        inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        inner_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = inner_ctx.alloc_reg();
        if (inner_ctx.next_reg <= call_base + 1) {
            inner_ctx.next_reg = call_base + 2;
        }
        ushort this_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Assign result to parameter register and sync to environment.
        // GETVAR reloads from env to pr because PUTVAR clears its source register.
        inner_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        inner_ctx.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
        inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to var_env — always executed (creates binding if deferred).
        inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        inner_ctx.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (inner_has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < inner_ctx.default_count; di++) {
                if (inner_ctx.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                inner_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit deferred outer-default checks for destructured parameters, now
    // that every parameter's arg slot is finalised (see
    // parse_destruct_param_default / emit_destruct_param_defaults).
    inner_ctx.emit_destruct_param_defaults();

    // Emit destructuring code — single pass walking synthetics then leaves.
    if (inner_destruct_count > 0) {
        for (uint di = 0; di < inner_destruct_count; di++) {
            ushort src_reg;
            if (inner_destruct_binds[di].parent_idx == 0xFFFF) {
                src_reg = inner_destruct_binds[di].arg_idx;
            } else {
                src_reg = inner_destruct_group_regs[inner_destruct_binds[di].parent_idx];
            }

            if (inner_destruct_binds[di].is_synthetic) {
                ushort group_reg = inner_ctx.alloc_reg();
                inner_destruct_group_regs[di] = group_reg;

                if (inner_destruct_binds[di].is_object) {
                    ushort key_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_a_bc(Opcode.LDCONST, (uint)key_reg, inner_destruct_binds[di].key_idx);
                    inner_ctx.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    inner_ctx.free_reg(key_reg);
                } else {
                    ushort key_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)inner_destruct_binds[di].index));
                    inner_ctx.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    inner_ctx.free_reg(key_reg);
                }

                // Default value check for nested patterns: if group_reg is
                // undefined, evaluate the default thunk before REQUIRE_OBJ.
                if (inner_destruct_binds[di].has_default) {
                    ushort undef_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)group_reg, (uint)undef_reg);
                    inner_ctx.free_reg(undef_reg);

                    uint skip_addr = inner_ctx.code_count;
                    inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    inner_ctx.free_reg(cmp_reg);

                    ushort closure_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, inner_destruct_binds[di].default_func_idx);

                    ushort call_base = inner_ctx.alloc_reg();
                    if (inner_ctx.next_reg <= call_base + 1) { inner_ctx.next_reg = call_base + 2; }
                    inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    inner_ctx.emit_abc(Opcode.LDREG, (uint)group_reg, (uint)call_base, 0);
                    inner_ctx.free_regs_to(call_base);

                    int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
                    inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                inner_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            } else {
                ushort bind_reg = inner_destruct_binding_regs[di];
                uint ni = inner_destruct_binds[di].name_idx;

                if (inner_destruct_binds[di].is_object) {
                    ushort key_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_a_bc(Opcode.LDCONST, (uint)key_reg, inner_destruct_binds[di].key_idx);
                    inner_ctx.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                    inner_ctx.free_reg(key_reg);
                } else {
                    if (inner_destruct_binds[di].key_idx == 0xFFFF) {
                        inner_ctx.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)src_reg, 0);
                    } else {
                        ushort key_reg = inner_ctx.alloc_reg();
                        inner_ctx.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)inner_destruct_binds[di].index));
                        inner_ctx.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                        inner_ctx.free_reg(key_reg);
                    }
                }

                if (inner_destruct_binds[di].has_default) {
                    ushort undef_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)bind_reg, (uint)undef_reg);
                    inner_ctx.free_reg(undef_reg);

                    uint skip_addr = inner_ctx.code_count;
                    inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    inner_ctx.free_reg(cmp_reg);

                    ushort closure_reg = inner_ctx.alloc_reg();
                    inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, inner_destruct_binds[di].default_func_idx);

                    ushort call_base = inner_ctx.alloc_reg();
                    if (inner_ctx.next_reg <= call_base + 1) { inner_ctx.next_reg = call_base + 2; }
                    inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    inner_ctx.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)call_base, 0);
                    inner_ctx.free_regs_to(call_base);

                    int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
                    inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)bind_reg, ni);
                inner_ctx.emit_a_bc(Opcode.GETVAR, (uint)bind_reg, ni);
            }
        }
    }

    // Hoist var and function declarations to the top of the inner function scope.
    inner_ctx.hoist_decls(false)!;

    // Compile function body
    inner_ctx.block(true)!;
    // Capture body-end position so Function.prototype.toString returns the
    // exact source span (without trailing whitespace / line-terminators).
    uint inner_body_end_pos = inner_ctx.lexer.pos;

    // Pop the function-level lexical scope
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Add implicit return undefined
    bool has_return = false;
    if (inner_ctx.code_count > 0) {
        Opcode last_op = inner_ctx.code[inner_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        inner_ctx.emit_simple((inner_ctx.is_generator && !inner_ctx.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }

    CompiledFunction* func = inner_ctx.finish()!;

    // Set function name. The name parameter is a slice into the caller's
    // inferred_name_buf (or a lexer token buffer), which gets reused for
    // subsequent function compilations. Copy the bytes into a heap allocation
    // that outlives the compile context, so each CompiledFunction holds its
    // own stable copy of its name.
    if (name.len > 0) {
        char* name_heap = (char*)libc::malloc((usz)name.len + 1);
        if (name_heap != null) {
            for (usz i = 0; i < (usz)name.len; i++) name_heap[i] = name[i];
            name_heap[name.len] = 0;
            func.name_ptr = name_heap;
            func.name_len = (uint)name.len;
            // Named function expression: tag so the VM creates a lexical
            // environment binding for `name` at call time (ES2015 §14.1.20).
            if (is_named_expr) {
                func.flags.is_namebinding = true;
            }
        }
    }

    // Retain a heap-owned copy of the function's source text so that
    // Function.prototype.toString can return the original source verbatim
    // (ES2019 §19.2.3.5). The caller passes the byte offset of the function's
    // opening token (`function` keyword, computed property `[`, arrow head,
    // etc.); `inner_body_end_pos` captures the position right after the
    // body's closing `}`, so the slice is exactly the function declaration.
    //
    // For `async function ...` the consumed `async` keyword is *before* the
    // byte offset we captured (we captured `function`), so we prepend the
    // literal "async " string to the retained source to match ES2019's source
    // text representation.
    if (src_start != 0xFFFFFFFF && src_start < (uint)inner_ctx.lexer.source.len) {
        uint src_end = inner_body_end_pos;
        if (src_end > (uint)inner_ctx.lexer.source.len) src_end = (uint)inner_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        bool needs_async_prefix = inner_ctx.is_async;
        usz alloc_len = (usz)slen + (needs_async_prefix ? (usz)6 : (usz)0);
        if (slen > 0) {
            char* src_heap = (char*)libc::malloc((usz)alloc_len + 1);
            if (src_heap != null) {
                usz off = 0;
                if (needs_async_prefix) {
                    src_heap[off++] = 'a';
                    src_heap[off++] = 's';
                    src_heap[off++] = 'y';
                    src_heap[off++] = 'n';
                    src_heap[off++] = 'c';
                    src_heap[off++] = ' ';
                }
                for (usz i = 0; i < (usz)slen; i++) src_heap[off + i] = inner_ctx.lexer.source[src_start + i];
                src_heap[off + (usz)slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = (uint)alloc_len;
            }
        }
    }

    return func;
}

/// Parse a function expression: function name?(...) { ... }
fn ushort? CompilerContext.function_expr(&self) {
    self.expect(TokenType.FUNCTION)!;
    // Capture the byte offset of `function` — used by Function.prototype.toString
    // for ES2019 §19.2.3.5 source-text retention.
    uint fexpr_src_start = self.lexer.token_start;

    // Save and reset generator state
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Save and reset async state
    bool saved_is_async = self.is_async;
    self.is_async = false;

    // Function expressions are constructable per ES2015 §14.1.2 — they can be
    // invoked with `new` unless they're arrow functions (handled in arrow
    // parsers) or method shorthand (constructor sets is_constructable=false
    // explicitly). Save/restore so nested functions inherit constructability.
    bool saved_is_constructable = self.is_constructable;
    self.is_constructable = true;

    // Check for generator star: function* name?() {}
    // Generator functions are never constructable (ES2015 §14.4) — `new` on
    // one must throw TypeError, so is_constructable must flip to false here.
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
        self.is_constructable = false;
    }

    // Optional function name. If the user didn't write one and we have an
    // inferred name from an enclosing `var f = ...` / `o = { m: ... }` /
    // object literal method shorthand, use the inferred name per ES2015
    // §14.1.20 SetFunctionName. Note: the inferred name does NOT create
    // a name binding (i.e. `f` is NOT visible inside the body), only the
    // display name on the function object.
    //
    // Always clear has_inferred_name after consumption — even when the user
    // provided an explicit name (`function bar() {}`), so a following
    // `var b = function() {}` doesn't inherit a stale name from `var a = function bar() {}`.
    char[] name;
    bool has_name = false;
    bool name_is_explicit = false;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
        has_name = true;
        name_is_explicit = true;
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    } else if (self.has_inferred_name) {
        name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        has_name = true;
        name_is_explicit = false;
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // Compile the function body into a sub-context.
    // Restore is_async so compile_inner_function propagates the flag,
    // then immediately reset to prevent nested functions from inheriting it.
    self.is_async = saved_is_async;
    // Use the byte offset of `function` captured right after expect() above.
    CompiledFunction* inner = self.compile_inner_function(name, name_is_explicit, fexpr_src_start)!;
    self.is_async = false;

    // Restore generator flag (async already reset above)
    self.is_generator = saved_is_generator;
    // Restore constructable flag
    self.is_constructable = saved_is_constructable;

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));

    return result;
}

/// Parse a function expression body (parameters + block) without the `function` keyword.
/// Used for method shorthand in object literals.
fn ushort? CompilerContext.function_expr_body(&self, uint src_start = 0xFFFFFFFF) {
    // ES2015 §14.3: object literal method shorthand `o = { m() {} }` —
    // the function's name is inferred from the property key. Caller
    // (object_literal / class_body parser) sets has_inferred_name before
    // calling. After consumption clear it so nested functions don't inherit.
    char[] name;
    if (self.has_inferred_name) {
        name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }
    // Capture byte offset of the opening of the method body — the caller
    // optionally supplies `src_start` if it knows the start of the full
    // declaration (e.g. `get f` for an object-literal getter, `[expr]` for a
    // computed key, or the leading `*` for a generator method). When the
    // caller doesn't supply one, fall back to the position of the `(` that
    // opens the parameter list (which is what we have just consumed).
    uint mexpr_src_start = src_start != 0xFFFFFFFF ? src_start : self.lexer.token_start;
    CompiledFunction* inner = self.compile_inner_function(name, false, mexpr_src_start)!;

    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse an arrow function by re-parsing the parameter list from source.
/// The lexer is positioned right after '(' when called. This function
/// re-parses params (including defaults, rest params, etc.) and compiles the body.
/// Called from primary_expr after the arrow detection scan confirms '=>' follows.
fn ushort? CompilerContext.parse_arrow_function_reparse(&self, uint src_start = 0xFFFFFFFF) {
    // Apply inferred name (from enclosing `var f = ...`) per ES2015 §14.1.20.
    char[] arrow_name;
    if (self.has_inferred_name) {
        arrow_name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // Create inner CompiledFunction for the arrow
    CompiledFunction* inner = self.compile_arrow_inner_reparse(src_start)!;

    if (arrow_name.len > 0) {
        char* name_heap = (char*)libc::malloc((usz)arrow_name.len + 1);
        if (name_heap != null) {
            for (usz i = 0; i < (usz)arrow_name.len; i++) name_heap[i] = arrow_name[i];
            name_heap[arrow_name.len] = 0;
            inner.name_ptr = name_heap;
            inner.name_len = (uint)arrow_name.len;
        }
    }

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function by re-parsing params from source.
/// The lexer is positioned right after '(' when called. This function
/// parses '(params) => body', handling defaults, rest params, etc.
fn CompiledFunction*? CompilerContext.compile_arrow_inner_reparse(&self, uint src_start = 0xFFFFFFFF) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // Propagate async: `async (params) => ...` bodies must run resumably
    // like async functions (AWAIT is only valid in an is_async context).
    arrow_ctx.is_async = self.is_async;
    if (arrow_ctx.is_async) arrow_ctx.is_generator = true;

    // Propagate class context (for super expressions)
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;

    // Parse parameter list from source (including defaults and rest)
    // Note: lexer is already past '(' when called from parse_arrow_function_reparse
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] arrow_destruct_binds;
    uint arrow_destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] arrow_destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] arrow_destruct_group_regs;

    if (!arrow_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (arrow_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...{a, b} or ...[a, b]
                if (arrow_ctx.check(TokenType.LBRACE)) {
                    arrow_ctx.advance()!;
                    arrow_ctx.alloc_reg();
                    arrow_ctx.collect_obj_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else if (arrow_ctx.check(TokenType.LBRACKET)) {
                    arrow_ctx.advance()!;
                    arrow_ctx.alloc_reg();
                    arrow_ctx.collect_arr_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = arrow_ctx.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    ushort rest_reg = arrow_ctx.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = arrow_ctx.add_string_constant(rest_param.str_value);
                    arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                arrow_ctx.has_rest = true;
                arrow_ctx.rest_formal_count = arg_count - 1;
                arrow_ctx.num_args = arg_count;
                arrow_ctx.formal_count = formal_count;
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (arrow_ctx.check(TokenType.LBRACE)) {
                arrow_ctx.advance()!;
                arrow_ctx.alloc_reg();
                arrow_ctx.collect_obj_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = arrow_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    arrow_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!arrow_ctx.match(TokenType.COMMA)) break;
                if (arrow_ctx.check(TokenType.RPAREN)) break;
                continue;
            } else if (arrow_ctx.check(TokenType.LBRACKET)) {
                arrow_ctx.advance()!;
                arrow_ctx.alloc_reg();
                arrow_ctx.collect_arr_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = arrow_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    arrow_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!arrow_ctx.match(TokenType.COMMA)) break;
                if (arrow_ctx.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = arrow_ctx.expect(TokenType.IDENTIFIER)!;
            ushort param_reg = arrow_ctx.declare_var(param.str_value, VAR);
            uint param_name_idx = arrow_ctx.add_string_constant(param.str_value);
            arg_count++;
            // DECLVAR creates binding in var_env.
            arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Check for default value
            if (arrow_ctx.check(TokenType.ASSIGN)) {
                arrow_ctx.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = arrow_ctx.compile_default_expr()!;

                // Add to inner functions table
                if (arrow_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = arrow_ctx.add_inner_func(default_func);
                    arrow_ctx.defaults[arrow_ctx.default_count].param_reg = param_reg;
                    arrow_ctx.defaults[arrow_ctx.default_count].param_name_idx = param_name_idx;
                    arrow_ctx.defaults[arrow_ctx.default_count].default_func_idx = def_idx;
                    arrow_ctx.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!arrow_ctx.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (arrow_ctx.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    if (!arrow_ctx.has_rest) {
        arrow_ctx.num_args = arg_count;
    }
    arrow_ctx.formal_count = formal_count;

    arrow_ctx.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables (skip synthetics).
    for (uint i = 0; i < arrow_destruct_count; i++) {
        if (arrow_destruct_binds[i].is_synthetic) {
            arrow_destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = arrow_destruct_binds[i].name_idx;
        char[] bind_name = arrow_destruct_binds[i].name_buf[:arrow_destruct_binds[i].name_len];
        ushort dreg = arrow_ctx.declare_var(bind_name, VAR);
        arrow_destruct_binding_regs[i] = dreg;
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }

    // Consume the => token
    arrow_ctx.expect(TokenType.ARROW)!;

    // Push a function-level lexical scope
    bool has_func_lex = arrow_ctx.default_count > 0;
    if (has_func_lex) {
        arrow_ctx.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            arrow_ctx.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            arrow_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < arrow_ctx.default_count; di++) {
        ushort pr = arrow_ctx.defaults[di].param_reg;
        uint name_idx = arrow_ctx.defaults[di].param_name_idx;
        uint func_idx = arrow_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        arrow_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = arrow_ctx.code_count;
        arrow_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        arrow_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = arrow_ctx.alloc_reg();
        if (arrow_ctx.next_reg <= call_base + 1) {
            arrow_ctx.next_reg = call_base + 2;
        }
        arrow_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        arrow_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        arrow_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Copy result directly to the parameter register.
        arrow_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        arrow_ctx.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        int skip_off = (int)arrow_ctx.code_count - (int)skip_addr - 1;
        arrow_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to var_env — always executed (creates binding if deferred).
        arrow_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        arrow_ctx.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < arrow_ctx.default_count; di++) {
                if (arrow_ctx.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                arrow_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit deferred outer-default checks for destructured parameters, now
    // that every parameter's arg slot is finalised (see
    // parse_destruct_param_default / emit_destruct_param_defaults).
    arrow_ctx.emit_destruct_param_defaults();

    // Emit destructuring code — single pass walking synthetics then leaves.
    if (arrow_destruct_count > 0) {
        for (uint di = 0; di < arrow_destruct_count; di++) {
            ushort src_reg;
            if (arrow_destruct_binds[di].parent_idx == 0xFFFF) {
                src_reg = arrow_destruct_binds[di].arg_idx;
            } else {
                src_reg = arrow_destruct_group_regs[arrow_destruct_binds[di].parent_idx];
            }

            if (arrow_destruct_binds[di].is_synthetic) {
                ushort group_reg = arrow_ctx.alloc_reg();
                arrow_destruct_group_regs[di] = group_reg;

                if (arrow_destruct_binds[di].is_object) {
                    ushort key_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_a_bc(Opcode.LDCONST, (uint)key_reg, arrow_destruct_binds[di].key_idx);
                    arrow_ctx.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    arrow_ctx.free_reg(key_reg);
                } else {
                    ushort key_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)arrow_destruct_binds[di].index));
                    arrow_ctx.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    arrow_ctx.free_reg(key_reg);
                }

                // Default value check for nested patterns: if group_reg is
                // undefined, evaluate the default thunk before REQUIRE_OBJ.
                if (arrow_destruct_binds[di].has_default) {
                    ushort undef_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)group_reg, (uint)undef_reg);
                    arrow_ctx.free_reg(undef_reg);

                    uint skip_addr = arrow_ctx.code_count;
                    arrow_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    arrow_ctx.free_reg(cmp_reg);

                    ushort closure_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, arrow_destruct_binds[di].default_func_idx);

                    ushort call_base = arrow_ctx.alloc_reg();
                    if (arrow_ctx.next_reg <= call_base + 1) { arrow_ctx.next_reg = call_base + 2; }
                    arrow_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    arrow_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    arrow_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    arrow_ctx.emit_abc(Opcode.LDREG, (uint)group_reg, (uint)call_base, 0);
                    arrow_ctx.free_regs_to(call_base);

                    int skip_off = (int)arrow_ctx.code_count - (int)skip_addr - 1;
                    arrow_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                arrow_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            } else {
                ushort bind_reg = arrow_destruct_binding_regs[di];
                uint ni = arrow_destruct_binds[di].name_idx;

                if (arrow_destruct_binds[di].is_object) {
                    ushort key_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_a_bc(Opcode.LDCONST, (uint)key_reg, arrow_destruct_binds[di].key_idx);
                    arrow_ctx.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                    arrow_ctx.free_reg(key_reg);
                } else {
                    if (arrow_destruct_binds[di].key_idx == 0xFFFF) {
                        arrow_ctx.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)src_reg, 0);
                    } else {
                        ushort key_reg = arrow_ctx.alloc_reg();
                        arrow_ctx.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)key_reg, (int)arrow_destruct_binds[di].index));
                        arrow_ctx.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                        arrow_ctx.free_reg(key_reg);
                    }
                }

                if (arrow_destruct_binds[di].has_default) {
                    ushort undef_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                    ushort cmp_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)bind_reg, (uint)undef_reg);
                    arrow_ctx.free_reg(undef_reg);

                    uint skip_addr = arrow_ctx.code_count;
                    arrow_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                    arrow_ctx.free_reg(cmp_reg);

                    ushort closure_reg = arrow_ctx.alloc_reg();
                    arrow_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, arrow_destruct_binds[di].default_func_idx);

                    ushort call_base = arrow_ctx.alloc_reg();
                    if (arrow_ctx.next_reg <= call_base + 1) { arrow_ctx.next_reg = call_base + 2; }
                    arrow_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                    arrow_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                    arrow_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                    arrow_ctx.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)call_base, 0);
                    arrow_ctx.free_regs_to(call_base);

                    int skip_off = (int)arrow_ctx.code_count - (int)skip_addr - 1;
                    arrow_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
                }

                arrow_ctx.emit_a_bc(Opcode.PUTVAR, (uint)bind_reg, ni);
                arrow_ctx.emit_a_bc(Opcode.GETVAR, (uint)bind_reg, ni);
            }
        }
    }

    // Determine if body is block or expression. Capture `body_end_pos` right
    // after the last body token (before any trailing whitespace or comment) so
    // Function.prototype.toString returns the exact source span.
    uint body_end_pos;
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        body_end_pos = arrow_ctx.lexer.pos;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
        body_end_pos = arrow_ctx.lexer.pos;
    }

    // Pop the function-level lexical scope
    if (has_func_lex) {
        arrow_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Set rest and formal counts before finish()
    arrow_ctx.num_args = arg_count;
    if (arrow_ctx.has_rest) {
        arrow_ctx.rest_formal_count = arg_count - 1;
    }

    CompiledFunction* func = arrow_ctx.finish()!;
    func.flags.is_arrow = true;

    // Retain source text for Function.prototype.toString (ES2019 §19.2.3.5).
    // See compile_inner_function for rationale. We use `body_end_pos` (captured
    // right after the last body token) as src_end so trailing whitespace and
    // comments after the body don't leak into the slice.
    if (src_start != 0xFFFFFFFF && src_start < (uint)arrow_ctx.lexer.source.len) {
        uint src_end = body_end_pos;
        // Trim trailing whitespace, line-terminators, and comments. The body
        // parser may have peeked-ahead, landing lexer.pos inside trailing
        // whitespace + comments. Walk back over trailing cruft.
        while (src_end > src_start) {
            char c = arrow_ctx.lexer.source[src_end - 1];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') {
                src_end--;
                continue;
            }
            // If we hit end-of-block-comment (`/` followed by `*`), scan
            // backward to find the matching `/*` and remove the whole
            // comment.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '*') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '*') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    i--;
                }
                if (!found) break;
                continue;
            }
            // Line comment: scan back to leading `//`.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '/') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '/') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    if (arrow_ctx.lexer.source[i - 1] == '\n') break;
                    i--;
                }
                if (!found) break;
                continue;
            }
            break;
        }
        if (src_end > (uint)arrow_ctx.lexer.source.len) src_end = (uint)arrow_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        if (slen > 0) {
            char* src_heap = (char*)libc::malloc((usz)slen + 1);
            if (src_heap != null) {
                for (usz i = 0; i < (usz)slen; i++) src_heap[i] = arrow_ctx.lexer.source[src_start + i];
                src_heap[slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = slen;
            }
        }
    }

    return func;
}

/// Parse an arrow function: `(params) => expr` or `(params) => { body }`
/// or `param => expr`.  The caller has already consumed the leading `(`
/// or the single identifier.
///
/// `params`: pre-parsed parameter name slices (pointer to first element).
/// `param_count`: number of parameters.
fn ushort? CompilerContext.parse_arrow_function(&self, char[]* params, ushort param_count, bool has_rest, uint src_start = 0xFFFFFFFF) {
    // Consume the ARROW token
    self.expect(TokenType.ARROW)!;

    // Create inner CompiledFunction for the arrow — apply inferred name
    // (from enclosing `var f = ...`) per ES2015 §14.1.20 SetFunctionName.
    char[] arrow_name;
    if (self.has_inferred_name) {
        arrow_name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }
    CompiledFunction* inner = self.compile_arrow_inner(params, param_count, has_rest, src_start)!;

    // Set the function's display name from the inferred source. This is a
    // non-binding name (no lexical scope entry) — only the name property.
    if (arrow_name.len > 0) {
        char* name_heap = (char*)libc::malloc((usz)arrow_name.len + 1);
        if (name_heap != null) {
            for (usz i = 0; i < (usz)arrow_name.len; i++) name_heap[i] = arrow_name[i];
            name_heap[arrow_name.len] = 0;
            inner.name_ptr = name_heap;
            inner.name_len = (uint)arrow_name.len;
        }
    }

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function given its parameter names.
/// Arrow functions have `is_arrow = true`, lexical `this`, and no `.prototype`.
fn CompiledFunction*? CompilerContext.compile_arrow_inner(&self, char[]* params, ushort param_count, bool has_rest, uint src_start = 0xFFFFFFFF) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // Propagate async: `async (params) => ...` bodies must run resumably
    // like async functions (AWAIT is only valid in an is_async context).
    arrow_ctx.is_async = self.is_async;
    if (arrow_ctx.is_async) arrow_ctx.is_generator = true;

    // Propagate class context (for super expressions)
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;

    // Register parameters
    ushort formal_count = param_count;
    if (has_rest && param_count > 0) {
        formal_count = param_count - 1;
    }
    for (ushort i = 0; i < param_count; i++) {
        char[] name = params[i];
        if (is_restricted_name(name)) {
            return COMPILE_ERROR~;
        }
        for (ushort j = 0; j < i; j++) {
            char[] prev = params[j];
            if (prev.len == name.len) {
                bool match = true;
                for (usz k = 0; k < name.len; k++) {
                    if (prev[k] != name[k]) { match = false; break; }
                }
                if (match) return COMPILE_ERROR~;
            }
        }
        ushort param_reg = arrow_ctx.declare_var(name, VAR);
        uint param_name_idx = arrow_ctx.add_string_constant(name);
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
    }

    // Push a function-level lexical scope
    arrow_ctx.emit_simple(Opcode.PUSH_LEX);

    // Determine if body is block or expression. Capture `body_end_pos` right
    // after the last body token (before any trailing whitespace or comment) so
    // Function.prototype.toString returns the exact source span.
    uint body_end_pos;
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        body_end_pos = arrow_ctx.lexer.pos;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
        body_end_pos = arrow_ctx.lexer.pos;
    }

    // Pop the function-level lexical scope
    arrow_ctx.emit_simple(Opcode.POP_LEX);

    // Set rest and formal counts before finish()
    arrow_ctx.has_rest = has_rest;
    arrow_ctx.rest_formal_count = formal_count;
    arrow_ctx.num_args = param_count;

    CompiledFunction* func = arrow_ctx.finish()!;
    func.flags.is_arrow = true;

    // Retain source text for Function.prototype.toString (ES2019 §19.2.3.5).
    // See compile_inner_function for rationale. We use `body_end_pos` (captured
    // right after the last body token) as src_end so trailing whitespace and
    // comments after the body don't leak into the slice.
    if (src_start != 0xFFFFFFFF && src_start < (uint)arrow_ctx.lexer.source.len) {
        uint src_end = body_end_pos;
        // Trim trailing whitespace, line-terminators, and comments. The body
        // parser may have peeked-ahead, landing lexer.pos inside trailing
        // whitespace + comments. Walk back over trailing cruft.
        while (src_end > src_start) {
            char c = arrow_ctx.lexer.source[src_end - 1];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') {
                src_end--;
                continue;
            }
            // If we hit end-of-block-comment (`/` followed by `*`), scan
            // backward to find the matching `/*` and remove the whole
            // comment.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '*') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '*') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    i--;
                }
                if (!found) break;
                continue;
            }
            // Line comment: scan back to leading `//`.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '/') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '/') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    if (arrow_ctx.lexer.source[i - 1] == '\n') break;
                    i--;
                }
                if (!found) break;
                continue;
            }
            break;
        }
        if (src_end > (uint)arrow_ctx.lexer.source.len) src_end = (uint)arrow_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        if (slen > 0) {
            char* src_heap = (char*)libc::malloc((usz)slen + 1);
            if (src_heap != null) {
                for (usz i = 0; i < (usz)slen; i++) src_heap[i] = arrow_ctx.lexer.source[src_start + i];
                src_heap[slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = slen;
            }
        }
    }

    return func;
}
