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
// Compiler-side module metadata (must match module::ModuleDef layout)
// ============================================================================

struct CompImportEntry {
    char[] local_name;
    char[] import_name;
    uint   req_module_idx;
    bool   is_star;
    bool   is_default;
}

struct CompExportEntry {
    char[] local_name;
    char[] export_name;
    bool   is_indirect;
    uint   req_module_idx;
}

struct CompStarExportEntry {
    uint req_module_idx;
}

struct CompReqModuleEntry {
    char[] module_name;
    void*  resolved;
}

const uint COMP_MAX_IMPORTS      = 64;
const uint COMP_MAX_EXPORTS      = 64;
const uint COMP_MAX_STAR_EXPORTS = 16;
const uint COMP_MAX_REQ_MODULES  = 32;

/// Compiler-side view of ModuleDef — field layout must match module::ModuleDef.
struct CompModuleDef {
    char[]                              module_name;
    char                                status;
    CompImportEntry[COMP_MAX_IMPORTS]   imports;
    uint                                import_count;
    CompExportEntry[COMP_MAX_EXPORTS]   exports;
    uint                                export_count;
    CompStarExportEntry[COMP_MAX_STAR_EXPORTS] star_exports;
    uint                                star_export_count;
    CompReqModuleEntry[COMP_MAX_REQ_MODULES] req_modules;
    uint                                req_module_count;
}

/// Register a required module specifier, returning its index (deduplicates).
fn uint mod_register_req_module(CompModuleDef* mod, char[] specifier) {
    for (uint i = 0; i < mod.req_module_count; i++) {
        if (mod.req_modules[i].module_name.len == specifier.len) {
            bool match = true;
            for (usz j = 0; j < specifier.len; j++) {
                if (mod.req_modules[i].module_name[j] != specifier[j]) { match = false; break; }
            }
            if (match) return i;
        }
    }
    if (mod.req_module_count >= COMP_MAX_REQ_MODULES) return 0;
    uint idx = mod.req_module_count;
    mod.req_modules[idx].module_name = specifier;
    mod.req_modules[idx].resolved = null;
    mod.req_module_count++;
    return idx;
}

/// Register an import entry in the module.
fn void mod_register_import(CompModuleDef* mod, char[] local_name, char[] import_name, uint req_idx, bool is_star, bool is_default) {
    if (mod.import_count >= COMP_MAX_IMPORTS) return;
    uint idx = mod.import_count;
    mod.imports[idx].local_name = local_name;
    mod.imports[idx].import_name = import_name;
    mod.imports[idx].req_module_idx = req_idx;
    mod.imports[idx].is_star = is_star;
    mod.imports[idx].is_default = is_default;
    mod.import_count++;
}

/// Register an export entry in the module.
fn void mod_register_export(CompModuleDef* mod, char[] local_name, char[] export_name, bool is_indirect, uint req_idx) {
    if (mod.export_count >= COMP_MAX_EXPORTS) return;
    uint idx = mod.export_count;
    mod.exports[idx].local_name = local_name;
    mod.exports[idx].export_name = export_name;
    mod.exports[idx].is_indirect = is_indirect;
    mod.exports[idx].req_module_idx = req_idx;
    mod.export_count++;
}

/// Register a star export entry in the module.
fn void mod_register_star_export(CompModuleDef* mod, uint req_idx) {
    if (mod.star_export_count >= COMP_MAX_STAR_EXPORTS) return;
    uint idx = mod.star_export_count;
    mod.star_exports[idx].req_module_idx = req_idx;
    mod.star_export_count++;
}

// ============================================================================
// Statement parsing
// ============================================================================

/// Parse and compile a single statement, dispatching on token type.
fn void? CompilerContext.statement(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.LBRACE:
            self.block(false)!;
        case TokenType.VAR:
            self.var_declaration()!;
        case TokenType.LET:
            self.var_declaration()!;
        case TokenType.CONST:
            self.var_declaration()!;
        case TokenType.IF:
            self.if_statement()!;
        case TokenType.WHILE:
            self.while_statement()!;
        case TokenType.DO:
            self.do_while_statement()!;
        case TokenType.FOR:
            self.for_statement()!;
        case TokenType.RETURN:
            self.return_statement()!;
        case TokenType.THROW:
            self.throw_statement()!;
        case TokenType.TRY:
            self.try_statement()!;
        case TokenType.SWITCH:
            self.switch_statement()!;
        case TokenType.WITH:
            return COMPILE_ERROR~;
        case TokenType.BREAK:
            self.break_statement()!;
        case TokenType.CONTINUE:
            self.continue_statement()!;
        case TokenType.FUNCTION:
            self.function_declaration()!;
        case TokenType.CLASS:
            self.class_declaration()!;
        case TokenType.IMPORT:
            self.import_declaration()!;
        case TokenType.EXPORT:
            self.export_declaration()!;
        case TokenType.SEMICOLON:
            // Empty statement
            self.advance()!;
        case TokenType.DEBUGGER:
            self.advance()!;
            self.emit_simple(Opcode.DEBUGGER);
            self.match(TokenType.SEMICOLON);
        default:
            // Check for labels: identifier : statement
            // We consume the identifier and check if the next token is ':'
            if (tt == TokenType.IDENTIFIER) {
                // Consume the identifier token to check what follows
                Token id_tok = self.advance()!;
                if (self.peek_type() == TokenType.COLON) {
                    self.advance()!; // consume ':'
                    self.labeled_statement(id_tok.str_value)!;
                    break;
                }

                // `async function name() {}` — treat as function declaration
                if (self.peek_type() == TokenType.FUNCTION &&
                    id_tok.str_value.len == 5 &&
                    id_tok.str_value[0] == 'a' && id_tok.str_value[1] == 's' &&
                    id_tok.str_value[2] == 'y' && id_tok.str_value[3] == 'n' &&
                    id_tok.str_value[4] == 'c') {
                    // id_tok was `async`; next token is `function`
                    self.is_async = true;
                    self.function_declaration()!;
                    self.is_async = false;
                    break;
                }

                // Not a label or async function — push the identifier back and fall through
                self.lexer.pushback(id_tok);
            }
            self.expression_statement()!;
    }
}

/// Check if a name is restricted in strict mode (ES5 §11.6.2.2, §12.10.1).
/// `eval` and `arguments` cannot be used as identifiers.
fn bool is_restricted_name(char[] name) @inline {
    if (name.len == 4 && name[0] == 'e' && name[1] == 'v' && name[2] == 'a' && name[3] == 'l') {
        return true;
    }
    if (name.len == 9 && name[0] == 'a' && name[1] == 'r' && name[2] == 'g' &&
        name[3] == 'u' && name[4] == 'm' && name[5] == 'e' &&
        name[6] == 'n' && name[7] == 't' && name[8] == 's') {
        return true;
    }
    return false;
}

/// Parse directive prologue statements at the start of a function body or program.
/// Detects "use strict" and enables strict mode if found (ES5 §14.1).
fn void? CompilerContext.parse_directives(&self) {
    while (true) {
        if (!self.check(TokenType.STRING)) {
            break;
        }

        Token str_tok = self.advance()!;

        bool has_semicolon = self.check(TokenType.SEMICOLON);
        bool has_asi = self.lexer.seen_line_term;

        if (has_semicolon || has_asi) {
            if (has_semicolon) {
                self.advance()!;
            }

            if (str_tok.str_value.len == 10) {
                bool is_use_strict = true;
                char[] expected = "use strict";
                for (usz i = 0; i < 10; i++) {
                    if (str_tok.str_value[i] != expected[i]) {
                        is_use_strict = false;
                        break;
                    }
                }
                // Strict-only engine: "use strict" directive is parsed and ignored
                // (no-op for source compatibility).
            }
        } else {
            self.lexer.pushback(str_tok);
            break;
        }
    }
}

/// Pre-scan tokens in the current block to find all `let`/`const` variable
/// declarations at the top level of the block (brace depth 0, excluding nested
/// blocks).  Saves and restores the lexer state so normal parsing can proceed
/// afterwards.
///
/// Returns the number of variable names found (0 to MAX_PRESCAN_NAMES).
/// Each name's position in the source text is stored in `spans` so the
/// caller can reconstruct the `char[]` slice from `lexer.source`.
fn uint CompilerContext.pre_scan_lexical_decls(&self, NameSpan* spans, uint capacity) {
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

    char* source_base = &self.lexer.source[0];

    uint     count       = 0;
    uint     brace_depth = 0;

    while (count < capacity) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) {
            break;
        }
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) {
            break;
        }

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }

        if (tt == TokenType.RBRACE) {
            if (brace_depth == 0) {
                break;   // end of the block we are scanning
            }
            brace_depth--;
            continue;
        }

        // Only collect let/const at the top level of this block (depth 0).
        if (brace_depth == 0 && (tt == TokenType.LET || tt == TokenType.CONST)) {
            // Collect one or more identifier names (comma-separated).
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) {
                    break;
                }
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) {
                    break;
                }
                // Store the name's position in the source text.
                if (count < capacity) {
                    spans[count].pos = (uint)((usz)name_tok.str_value.ptr - (usz)source_base);
                    spans[count].len = (uint)name_tok.str_value.len;
                    count++;
                }
                // Check for comma (multiple declarations).
                Token? sep_opt = self.lexer.next_token();
                if (catch _err3 = sep_opt) {
                    break;
                }
                Token sep = sep_opt;
                if (sep.type != TokenType.COMMA) {
                    break;
                }
                // continue to the next declarator name
            }
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

    return count;
}

/// Parse a block: { statement* }
/// If `check_directives` is true, checks for "use strict" directive prologue at the start.
fn void? CompilerContext.block(&self, bool check_directives) {
    self.expect(TokenType.LBRACE)!;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Push a scope marker so duplicate let/const checks stop at this block boundary.
    self.push_scope_marker();

    // Pre-scan for let/const declarations at this block level so we can
    // TDZ-initialize them at block entry (before any code in the block runs).
    NameSpan[MAX_PRESCAN_NAMES] lex_spans;
    uint num_lex = self.pre_scan_lexical_decls(&lex_spans, MAX_PRESCAN_NAMES);

    // Push a new lexical scope for let/const declarations inside this block.
    // Skip when the block has no let/const — saves an allocation on every
    // function call (most functions have no block-scoped variables).
    bool has_lex = num_lex > 0;
    if (has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
    }

    // TDZ-initialize every let/const declaration found by the pre-scan.
    // This ensures that accessing the variable before its declaration
    // throws a ReferenceError (temporal dead zone) instead of finding
    // an outer `var` binding or returning undefined.
    for (uint i = 0; i < num_lex; i++) {
        char[] name = self.lexer.source[lex_spans[i].pos..lex_spans[i].pos + lex_spans[i].len - 1];
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);

        // Mark the outer scope_stack entry as captured so that the compiler
        // emits GETVAR instead of LDREG for this variable.  Without this,
        // a register-cached value from an outer scope would bypass the TDZ
        // sentinel in the new lex_env.
        for (uint j = 0; j < saved_depth; j++) {
            if (str_eq(self.scope_stack[j].name, name)) {
                self.scope_stack[j].is_captured = true;
                break;
            }
        }
    }

    if (check_directives) {
        self.parse_directives()!;
    }

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        self.statement()!;
    }

    self.expect(TokenType.RBRACE)!;

    // Pop the lexical scope, removing any let/const bindings from this block
    if (has_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

/// Emit the environment store for a declared variable (PUTVAR or PUTLEX/PUTLEX_C).
fn void CompilerContext.emit_var_store(&self, ushort reg, uint name_idx, bool is_lexical, bool is_const) {
    if (is_lexical) {
        if (is_const) {
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)reg, name_idx);
        } else {
            self.emit_a_bc(Opcode.PUTLEX, (uint)reg, name_idx);
        }
    } else {
        // DECLVAR declares the binding in the immediate var_env (function-scoped).
        // PUTVAR (plain assignment) walks the chain to update existing bindings.
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
    }
}

/// Parse var/let/const declaration.
fn void? CompilerContext.var_declaration(&self) {
    Token decl_tok = self.advance()!;
    bool is_const = (decl_tok.type == TokenType.CONST);
    bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
    ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

    // var declarations are hoisted to function scope — need env allocation.
    if (!is_lexical) {
        self.has_local_bindings = true;
    }

    // Parse one or more variable declarators
    for (;;) {
        TokenType next = self.peek_type();

        if (next == TokenType.LBRACKET) {
            self.advance()!; // consume '['
            self.array_destructure(kind, is_lexical, is_const)!;
        } else if (next == TokenType.LBRACE) {
            self.advance()!; // consume '{'
            self.object_destructure(kind, is_lexical, is_const)!;
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort reg;
            bool already_declared = false;
            if (!is_lexical) {
                // var declarations: check if already declared (from hoisting
                // or from an outer var declaration in the same function).
                // If so, reuse the existing register and skip DECLVAR/LDUNDEF.
                ushort? existing = self.resolve_var(name_tok.str_value);
                if (try er = existing) {
                    reg = er;
                    already_declared = true;
                } else {
                    reg = self.declare_var(name_tok.str_value, kind);
                }
            } else {
                // Check for duplicate let/const in the same block scope (ES6 §13.3.1)
                if (is_lexical) {
                    uint i = self.scope_depth;
                    while (i > 0) {
                        i--;
                        // Stop at VAR entries (function-scope boundary) or
                        // SCOPEMARK entries (block-scope boundary).
                        if (self.scope_stack[i].kind == VAR || self.scope_stack[i].kind == SCOPEMARK) break;
                        if (str_eq(self.scope_stack[i].name, name_tok.str_value) &&
                            (self.scope_stack[i].kind == LET || self.scope_stack[i].kind == CONST)) {
                            return COMPILE_ERROR~;
                        }
                    }
                }
                reg = self.declare_var(name_tok.str_value, kind);
            }
            ushort saved_reg = self.next_reg;

            // Optional initializer
            bool has_init = false;
            if (self.match(TokenType.ASSIGN)) {
                ushort val_reg = self.assignment_expr()!;
                if (val_reg != reg) {
                    self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                }
                self.free_reg(val_reg);
                has_init = true;
            } else if (!already_declared) {
                if (is_const) {
                    return COMPILE_ERROR~;
                }
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }

            // Store in the environment so inner functions can find it
            // var → var_env (function-scoped), let/const → lex_env (block-scoped)
            // For already-declared vars, only emit store if there's an initializer
            if (!already_declared || has_init) {
                uint name_idx = self.add_string_constant(name_tok.str_value);
                self.emit_var_store(reg, name_idx, is_lexical, is_const);
            }

            // At global scope, free the var register and any leaked temporaries
            // from the initializer evaluation.  Global vars use PUTVAR/GETVAR
            // at runtime — the register is only needed briefly as the PUTVAR source.
            // Lexical declarations (let/const) at global scope have their registers
            // managed by pop_scope_to() from the enclosing block() or from the
            // top-level compile() cleanup.
            if (self.is_global) {
                if (!is_lexical) {
                    self.free_reg(reg);
                }
                self.free_regs_to(saved_reg);
            }
        }

        if (!self.match(TokenType.COMMA)) {
            break;
        }
    }

    self.match(TokenType.SEMICOLON);
}



/// Parse if/else statement.
fn void? CompilerContext.if_statement(&self) {
    self.expect(TokenType.IF)!;
    self.expect(TokenType.LPAREN)!;

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Emit conditional jump (skip then-branch if false)
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile then-branch
    self.statement()!;

    if (self.match(TokenType.ELSE)) {
        // Emit jump over else-branch
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // Compile else-branch
        self.statement()!;

        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

/// Parse while statement.
fn void? CompilerContext.while_statement(&self) {
    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    // --- Rotated while-loop layout ---
    //
    //   JUMP → cond_label              (zero-iteration check)
    //   body_label:
    //     <body>
    //   cond_label:                    ← continue targets HERE
    //     <condition>
    //     IF_TRUE → body_label         (back edge; fused → JMP_LT etc.)
    //   exit:                          ← break patches here
    //
    // The condition appears BEFORE the body in source, so we save the lexer
    // state here, skip the condition tokens, compile the body, then restore
    // and compile the condition.  This mirrors the for-loop's rotation.

    // ----------------------------------------------------------------
    // Step 0: Save lexer state at start of condition.
    // ----------------------------------------------------------------
    uint  _cond_pos; uint  _cond_line; uint  _cond_col;
    Token _cond_cur; Token _cond_look; bool  _cond_haslk;
    Token _cond_push; bool _cond_haspb; bool _cond_slt;
    uint  _cond_pbc;  Token[4] _cond_pbs;
    _cond_pos   = self.lexer.pos;
    _cond_line  = self.lexer.line;
    _cond_col   = self.lexer.col;
    _cond_cur   = self.lexer.current;
    _cond_look  = self.lexer.lookahead;
    _cond_haslk = self.lexer.has_lookahead;
    _cond_push  = self.lexer.pushed_back;
    _cond_haspb = self.lexer.has_pushed_back;
    _cond_slt   = self.lexer.seen_line_term;
    _cond_pbc   = self.pushback_count;
    _cond_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 1: Check for while(true) — constant true, skip rotate overhead.
    //         Also detect simple `<ident> <relop> <numeric literal>` condition.
    // ----------------------------------------------------------------
    bool is_const_true = false;
    bool has_simple_cond = false;
    double simple_cond_rhs = 0.0;
    Opcode simple_cond_op = Opcode.LT;
    ushort pinned_rhs_reg = 0;

    // Probe up to 4 tokens to detect simple patterns (only when pushback is clean).
    if (_cond_pbc == 0 && !_cond_haspb && !_cond_haslk) {
        Token? t1o = self.lexer.next_token();
        if (try t1 = t1o) {
            // while(true) — 'true' is lexed as an IDENTIFIER with str_value "true"
            if (t1.type == TokenType.IDENTIFIER && str_eq(t1.str_value, "true")) {
                Token? t2o = self.lexer.next_token();
                if (try t2 = t2o) {
                    if (t2.type == TokenType.RPAREN) {
                        is_const_true = true;
                    } else {
                        self.pushback(t2);
                    }
                }
            }
            // while(ident <relop> number)
            if (!is_const_true && t1.type == TokenType.IDENTIFIER) {
                Token? t2o = self.lexer.next_token();
                if (try t2 = t2o) {
                    Token? t3o = self.lexer.next_token();
                    if (try t3 = t3o) {
                        Token? t4o = self.lexer.next_token();
                        if (try t4 = t4o) {
                            bool is_relop = (t2.type == TokenType.LT || t2.type == TokenType.LE
                                          || t2.type == TokenType.GT || t2.type == TokenType.GE);
                            bool is_num   = (t3.type == TokenType.NUMBER);
                            bool is_rp    = (t4.type == TokenType.RPAREN);
                            if (is_relop && is_num && is_rp) {
                                has_simple_cond = true;
                                simple_cond_rhs = t3.num_value;
                                switch (t2.type) {
                                    case TokenType.LT: simple_cond_op = Opcode.LT;
                                    case TokenType.LE: simple_cond_op = Opcode.LE;
                                    case TokenType.GT: simple_cond_op = Opcode.GT;
                                    default:           simple_cond_op = Opcode.GE;
                                }
                            }
                        }
                    }
                }
            }
            if (!is_const_true) {
                self.pushback(t1);
            }
        }
        // Restore lexer to start of condition.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
    }

    // ----------------------------------------------------------------
    // Step 2: Pre-load pinned RHS register (before initial JUMP).
    // ----------------------------------------------------------------
    if (has_simple_cond) {
        pinned_rhs_reg = self.alloc_reg();
        int int_rhs = (int)simple_cond_rhs;
        if ((double)int_rhs == simple_cond_rhs
            && int_rhs >= bytecode::MIN_SBC && int_rhs <= bytecode::MAX_SBC) {
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs));
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx));
        }
    }

    // ----------------------------------------------------------------
    // Step 3: Emit initial JUMP → cond_label and record body_label.
    // ----------------------------------------------------------------
    uint cond_jump = 0;
    if (!is_const_true) {
        cond_jump = self.emit_jump(Opcode.JUMP);  // forward → cond_label
    }
    uint body_label = self.code_count;

    // ----------------------------------------------------------------
    // Step 4: Skip condition tokens (no code emitted) and consume ')'.
    // ----------------------------------------------------------------
    // skip_expr_lex scans until `)` at depth 0, leaving it in pushed_back.
    self.skip_expr_lex();
    self.expect(TokenType.RPAREN)!;  // consume ')'

    // ----------------------------------------------------------------
    // Step 5: Push loop (continue_target = body_label placeholder;
    //          updated to cond_label in Step 7).
    // ----------------------------------------------------------------
    self.push_loop(body_label, true);
    self.statement()!;

    // Save post-body lexer state — outer parser resumes here after return.
    uint  _post_pos; uint  _post_line; uint  _post_col;
    Token _post_cur; Token _post_look; bool  _post_haslk;
    Token _post_push; bool _post_haspb; bool _post_slt;
    uint  _post_pbc;  Token[4] _post_pbs;
    _post_pos   = self.lexer.pos;   _post_line  = self.lexer.line;   _post_col   = self.lexer.col;
    _post_cur   = self.lexer.current; _post_look  = self.lexer.lookahead;
    _post_haslk = self.lexer.has_lookahead; _post_push  = self.lexer.pushed_back;
    _post_haspb = self.lexer.has_pushed_back; _post_slt = self.lexer.seen_line_term;
    _post_pbc   = self.pushback_count; _post_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 6: cond_label — patch initial JUMP and update continue_target.
    // ----------------------------------------------------------------
    uint cond_label = self.code_count;
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = cond_label;
    }
    if (!is_const_true) {
        self.patch_jump(cond_jump);
    }

    // ----------------------------------------------------------------
    // Step 7: Compile condition with IF_TRUE back edge to body_label.
    // ----------------------------------------------------------------
    if (is_const_true) {
        // while(true) — unconditional back edge.
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, back));
    } else if (has_simple_cond) {
        // Restore lexer to condition start, compile with pinned RHS.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
        Token ident_tok = self.advance()!;
        Token _relop    = self.advance()!;   // consume relop
        Token _num_tok  = self.advance()!;   // consume NUMBER (value in pinned_rhs_reg)
        self.expect(TokenType.RPAREN)!;      // consume ')'

        ushort lhs_reg = self.alloc_reg();
        if (!self.is_global) {
            if (try reg = self.resolve_var(ident_tok.str_value)) {
                if (reg != lhs_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)lhs_reg, (uint)reg, 0);
                }
            } else {
                uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
            }
        } else {
            uint name_idx2 = self.add_string_constant(ident_tok.str_value);
            self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
        }
        ushort cmp_res = self.alloc_reg();
        self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
        self.free_reg(lhs_reg);
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_res, back));
        self.free_reg(cmp_res);
        self.free_reg(pinned_rhs_reg);
    } else {
        // General condition: restore and re-compile normally.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
        ushort cond_reg = self.expression()!;
        self.expect(TokenType.RPAREN)!;
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back));
        self.free_reg(cond_reg);
    }

    // exit: pop_loop patches all break jumps and resolves continue patches.
    self.pop_loop();

    // Restore the lexer to the position after the body.
    self.lexer.pos = _post_pos; self.lexer.line = _post_line; self.lexer.col = _post_col;
    self.lexer.current = _post_cur; self.lexer.lookahead = _post_look;
    self.lexer.has_lookahead = _post_haslk; self.lexer.pushed_back = _post_push;
    self.lexer.has_pushed_back = _post_haspb; self.lexer.seen_line_term = _post_slt;
    self.pushback_count = _post_pbc; self.pushback_stack = _post_pbs;

    self.match(TokenType.SEMICOLON);
}

/// Parse for statement (basic for, for-in, for-of).
fn void? CompilerContext.for_statement(&self) {
    self.expect(TokenType.FOR)!;
    self.expect(TokenType.LPAREN)!;

    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Track for-init var so we can emit PUTVAR after the increment to sync
    // the register-cached value back to the environment (needed so closures
    // inside the loop and code after the loop see the correct final value).
    bool has_for_var = false;
    bool is_lexical = false;
    ushort for_var_reg = 0;
    uint for_var_name_idx = 0;

    // Check for for-in / for-of
    TokenType next_tt = self.peek_type();

    // Check for bare for-of: for (x of expr)
    if (next_tt == TokenType.IDENTIFIER) {
        Token id_tok = self.advance()!;
        if (try tok2 = self.lexer.peek()) {
            if (tok2.type == TokenType.IDENTIFIER && str_eq(tok2.str_value, "of")) {
                self.advance()!;  // consume "of"
                ushort iter_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;
                uint name_idx = self.add_string_constant(id_tok.str_value);
                self.emit_forof_loop(id_tok.str_value, iter_reg, saved_scope, saved_reg, false, false, true)!;
                return;
            }
        }
        self.pushback(id_tok);
    }

    // Parse init (may be var/let/const or expression or empty)
    if (next_tt == TokenType.VAR || next_tt == TokenType.LET || next_tt == TokenType.CONST) {
        // Check if it's for-in: "var x in ..."
        // We parse the variable declaration keyword
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
        ScopeKind decl_kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

        // Check for destructuring: [pattern] or {pattern}
        TokenType after_decl = self.peek_type();
        if (after_decl == TokenType.LBRACKET || after_decl == TokenType.LBRACE) {
            // Check if this is a for-of or for-in with destructuring
            // We need to look ahead past the pattern to see if 'of' or 'in' follows
            bool is_forof_destr = false;
            bool is_forin_destr = false;

            // Save lexer state to look ahead
            uint saved_pos = self.lexer.pos;
            uint saved_line = self.lexer.line;
            uint saved_col = self.lexer.col;
            Token saved_cur = self.lexer.current;
            Token saved_look = self.lexer.lookahead;
            bool saved_haslk = self.lexer.has_lookahead;
            Token saved_push = self.lexer.pushed_back;
            bool saved_haspb = self.lexer.has_pushed_back;
            bool saved_slt = self.lexer.seen_line_term;

            // Skip past the pattern tokens to find 'of' or 'in'
            self.advance()!; // consume '[' or '{'
            uint depth = 1;
            while (depth > 0) {
                Token? next_opt = self.lexer.next_token();
                if (try next = next_opt) {
                    if (next.type == TokenType.LBRACKET || next.type == TokenType.LBRACE) {
                        depth++;
                    } else if (next.type == TokenType.RBRACKET || next.type == TokenType.RBRACE) {
                        depth--;
                    } else if (next.type == TokenType.EOF_TOKEN) {
                        break;
                    }
                } else {
                    break;
                }
            }

            // Now check what follows the pattern
            Token? peek_tok = self.lexer.peek();
            if (try pt = peek_tok) {
                if (pt.type == TokenType.IDENTIFIER && str_eq(pt.str_value, "of")) {
                    is_forof_destr = true;
                } else if (pt.type == TokenType.IN) {
                    is_forin_destr = true;
                }
            }

            // Restore lexer state
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.col = saved_col;
            self.lexer.current = saved_cur;
            self.lexer.lookahead = saved_look;
            self.lexer.has_lookahead = saved_haslk;
            self.lexer.pushed_back = saved_push;
            self.lexer.has_pushed_back = saved_haspb;
            self.lexer.seen_line_term = saved_slt;

            if (is_forof_destr) {
                // for (let [a, b] of arr) or for (let {x, y} of arr)
                bool is_array_pattern = (after_decl == TokenType.LBRACKET);
                ushort iter_reg = 0;

                // ── Parse the destructuring pattern inline ──
                // We parse bindings here and emit iterator-based extraction
                // into the loop body below, avoiding lexer state issues with
                // destructure_for_value (which can't re-parse after the header
                // has been consumed).

                ArrayBind[32] arr_binds;
                ObjBind[32]   obj_binds;
                uint bind_count = 0;

                if (is_array_pattern) {
                    self.advance()!; // consume '['
                    for (;;) {
                        if (self.check(TokenType.RBRACKET)) break;

                        if (self.check(TokenType.COMMA)) {
                            self.advance()!;
                            if (bind_count < 32) {
                                arr_binds[bind_count].is_hole = true;
                                arr_binds[bind_count].has_default = false;
                                bind_count++;
                            }
                            continue;
                        }

                        if (self.match(TokenType.ELLIPSIS)) {
                            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(rest_tok.str_value, decl_kind);
                                arr_binds[bind_count].reg = reg;
                                arr_binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                                arr_binds[bind_count].is_rest = true;
                                arr_binds[bind_count].is_hole = false;
                                arr_binds[bind_count].has_default = false;
                                bind_count++;
                            }
                            while (self.match(TokenType.COMMA)) {}
                            break;
                        }

                        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg = self.declare_var(name_tok.str_value, decl_kind);
                            arr_binds[bind_count].reg = reg;
                            arr_binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                            arr_binds[bind_count].is_rest = false;
                            arr_binds[bind_count].is_hole = false;
                            arr_binds[bind_count].has_default = false;

                            if (self.match(TokenType.ASSIGN)) {
                                arr_binds[bind_count].has_default = true;
                                arr_binds[bind_count].default_val_reg = self.assignment_expr()!;
                            }

                            bind_count++;
                        }

                        if (!self.match(TokenType.COMMA)) break;
                    }
                    self.expect(TokenType.RBRACKET)!;
                } else {
                    // Object pattern
                    self.advance()!; // consume '{'
                    if (!self.check(TokenType.RBRACE)) {
                        for (;;) {
                            Token prop_tok = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;

                            if (self.match(TokenType.COLON)) {
                                if (self.check(TokenType.LBRACE)) {
                                    self.advance()!;
                                    Token nested_tok = self.expect(TokenType.IDENTIFIER)!;
                                    if (is_restricted_name(nested_tok.str_value)) return COMPILE_ERROR~;
                                    self.expect(TokenType.RBRACE)!;
                                    if (bind_count < 32) {
                                        ushort reg = self.declare_var(nested_tok.str_value, decl_kind);
                                        obj_binds[bind_count].reg = reg;
                                        obj_binds[bind_count].name_idx = self.add_string_constant(nested_tok.str_value);
                                        obj_binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                        obj_binds[bind_count].has_default = false;
                                        obj_binds[bind_count].is_nested = true;
                                        obj_binds[bind_count].nested_key_idx = self.add_string_constant(nested_tok.str_value);

                                        if (self.match(TokenType.ASSIGN)) {
                                            obj_binds[bind_count].has_default = true;
                                            obj_binds[bind_count].default_val_reg = self.assignment_expr()!;
                                        }

                                        bind_count++;
                                    }
                                } else {
                                    Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                                    if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                                    if (bind_count < 32) {
                                        ushort reg = self.declare_var(bind_tok.str_value, decl_kind);
                                        obj_binds[bind_count].reg = reg;
                                        obj_binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                                        obj_binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                        obj_binds[bind_count].has_default = false;

                                        if (self.match(TokenType.ASSIGN)) {
                                            obj_binds[bind_count].has_default = true;
                                            obj_binds[bind_count].default_val_reg = self.assignment_expr()!;
                                        }

                                        bind_count++;
                                    }
                                }
                            } else {
                                // Shorthand: {name}
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(prop_tok.str_value, decl_kind);
                                    obj_binds[bind_count].reg = reg;
                                    obj_binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                                    obj_binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                    obj_binds[bind_count].has_default = false;

                                    if (self.match(TokenType.ASSIGN)) {
                                        obj_binds[bind_count].has_default = true;
                                        obj_binds[bind_count].default_val_reg = self.assignment_expr()!;
                                    }

                                    bind_count++;
                                }
                            }

                            if (!self.match(TokenType.COMMA)) break;
                        }
                    }
                    self.expect(TokenType.RBRACE)!;
                }

                // Consume "of" (contextual keyword - lexed as IDENTIFIER)
                {
                    Token of_tok = self.expect(TokenType.IDENTIFIER)!;
                    if (!str_eq(of_tok.str_value, "of")) {
                        return COMPILE_ERROR~;
                    }
                }

                iter_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                // ── Outer iterator protocol setup ──
                ushort sym_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

                ushort iter_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

                ushort symbol_val_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
                self.free_reg(iter_key_reg);
                self.free_reg(sym_reg);

                ushort method_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
                self.free_reg(symbol_val_reg);

                ushort this_slot = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
                self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
                self.free_reg(this_slot);

                ushort next_reg = self.alloc_reg();
                ushort next_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
                self.free_reg(next_key_reg);

                ushort callee_reg = self.alloc_reg();
                ushort callee_this_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
                self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

                // ── Loop ──
                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                ushort result_reg = self.alloc_reg();
                self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

                ushort done_key_reg = self.alloc_reg();
                ushort done_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
                uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

                ushort value_key_reg = self.alloc_reg();
                ushort val_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

                // ── Destructure the yielded value ──
                if (is_array_pattern) {
                    if (bind_count > 0) {
                        // Inner iterator on val_reg
                        ushort inner_sym_reg = self.alloc_reg();
                        self.emit_a_bc(Opcode.GETVAR, (uint)inner_sym_reg, self.add_string_constant("Symbol"));

                        ushort inner_iter_key_reg = self.alloc_reg();
                        self.emit_abc(Opcode.LDCONST, (uint)inner_iter_key_reg, self.add_string_constant("iterator"), 0);

                        ushort inner_symbol_val_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROP, (uint)inner_symbol_val_reg, (uint)inner_sym_reg, (uint)inner_iter_key_reg);
                        self.free_reg(inner_iter_key_reg);
                        self.free_reg(inner_sym_reg);

                        ushort inner_method_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROP, (uint)inner_method_reg, (uint)val_reg, (uint)inner_symbol_val_reg);
                        self.free_reg(inner_symbol_val_reg);

                        ushort inner_this_reg = self.alloc_reg();
                        self.emit_abc(Opcode.LDREG, (uint)inner_this_reg, (uint)val_reg, 0);
                        self.emit_abc(Opcode.CALL, (uint)inner_method_reg, (uint)inner_method_reg, 0);
                        self.free_reg(inner_this_reg);

                        ushort inner_next_reg = self.alloc_reg();
                        ushort inner_next_key_reg = self.alloc_reg();
                        self.emit_abc(Opcode.LDCONST, (uint)inner_next_key_reg, self.add_string_constant("next"), 0);
                        self.emit_abc(Opcode.GETPROP, (uint)inner_next_reg, (uint)inner_method_reg, (uint)inner_next_key_reg);
                        self.free_reg(inner_next_key_reg);

                        ushort inner_callee_reg = self.alloc_reg();
                        ushort inner_callee_this_reg = self.alloc_reg();
                        self.emit_abc(Opcode.LDREG, (uint)inner_callee_reg, (uint)inner_next_reg, 0);
                        self.emit_abc(Opcode.LDREG, (uint)inner_callee_this_reg, (uint)inner_method_reg, 0);

                        for (uint bi = 0; bi < bind_count; bi++) {
                            if (arr_binds[bi].is_hole) {
                                ushort hole_result = self.alloc_reg();
                                self.emit_abc(Opcode.CALL, (uint)hole_result, (uint)inner_callee_reg, 0);
                                self.free_reg(hole_result);
                                continue;
                            }

                            if (arr_binds[bi].is_rest) {
                                ushort arr_reg = self.alloc_reg();
                                self.emit_abc(Opcode.NEWARR, (uint)arr_reg, 0, 0);

                                uint collect_start = self.code_count;

                                ushort inner_result_reg = self.alloc_reg();
                                self.emit_abc(Opcode.CALL, (uint)inner_result_reg, (uint)inner_callee_reg, 0);

                                ushort inner_done_key_reg = self.alloc_reg();
                                ushort inner_done_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDCONST, (uint)inner_done_key_reg, self.add_string_constant("done"), 0);
                                self.emit_abc(Opcode.GETPROP, (uint)inner_done_reg, (uint)inner_result_reg, (uint)inner_done_key_reg);
                                uint inner_done_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)inner_done_reg);

                                ushort inner_val_key_reg = self.alloc_reg();
                                ushort inner_val_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDCONST, (uint)inner_val_key_reg, self.add_string_constant("value"), 0);
                                self.emit_abc(Opcode.GETPROP, (uint)inner_val_reg, (uint)inner_result_reg, (uint)inner_val_key_reg);
                                self.free_reg(inner_val_key_reg);
                                self.free_reg(inner_result_reg);

                                ushort push_key_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDCONST, (uint)push_key_reg, self.add_string_constant("push"), 0);
                                ushort push_method_reg = self.alloc_reg();
                                self.emit_abc(Opcode.GETPROP, (uint)push_method_reg, (uint)arr_reg, (uint)push_key_reg);
                                self.free_reg(push_key_reg);

                                ushort push_callee_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDREG, (uint)push_callee_reg, (uint)push_method_reg, 0);
                                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 1), (uint)arr_reg, 0);
                                if (self.next_reg < push_callee_reg + 3) {
                                    self.next_reg = push_callee_reg + 3;
                                }
                                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 2), (uint)inner_val_reg, 0);
                                self.free_reg(inner_val_reg);
                                self.free_reg(push_method_reg);
                                self.emit_abc(Opcode.CALL, (uint)push_callee_reg, (uint)push_callee_reg, 1);

                                int back_off = (int)collect_start - (int)self.code_count - 1;
                                self.emit(bytecode::make_sabc(Opcode.JUMP, back_off));

                                self.patch_jump(inner_done_jump);

                                self.free_reg(inner_done_key_reg);
                                self.free_reg(inner_done_reg);

                                self.emit_abc(Opcode.LDREG, (uint)arr_binds[bi].reg, (uint)arr_reg, 0);
                                self.free_reg(arr_reg);
                            } else {
                                ushort inner_result_reg = self.alloc_reg();
                                self.emit_abc(Opcode.CALL, (uint)inner_result_reg, (uint)inner_callee_reg, 0);

                                ushort inner_val_key_reg = self.alloc_reg();
                                ushort inner_val_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDCONST, (uint)inner_val_key_reg, self.add_string_constant("value"), 0);
                                self.emit_abc(Opcode.GETPROP, (uint)inner_val_reg, (uint)inner_result_reg, (uint)inner_val_key_reg);
                                self.free_reg(inner_val_key_reg);
                                self.free_reg(inner_result_reg);

                                self.emit_abc(Opcode.LDREG, (uint)arr_binds[bi].reg, (uint)inner_val_reg, 0);
                                self.free_reg(inner_val_reg);

                                if (arr_binds[bi].has_default) {
                                    ushort undef_reg = self.alloc_reg();
                                    self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                                    ushort is_undef_reg = self.alloc_reg();
                                    self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)arr_binds[bi].reg, (uint)undef_reg);
                                    self.free_reg(undef_reg);
                                    uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                                    self.free_reg(is_undef_reg);
                                    self.emit_abc(Opcode.LDREG, (uint)arr_binds[bi].reg, (uint)arr_binds[bi].default_val_reg, 0);
                                    self.patch_jump(skip_default);
                                    self.free_reg(arr_binds[bi].default_val_reg);
                                }
                            }

                            self.emit_var_store(arr_binds[bi].reg, arr_binds[bi].name_idx, is_lexical, is_const);
                        }

                        self.free_reg(inner_callee_this_reg);
                        self.free_reg(inner_callee_reg);
                        self.free_reg(inner_next_reg);
                        self.free_reg(inner_method_reg);
                    }
                } else {
                    // Object destructuring: GETPROP with string keys
                    for (uint bi = 0; bi < bind_count; bi++) {
                        if (obj_binds[bi].is_nested) {
                            ushort parent_key_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)parent_key_reg, obj_binds[bi].key_idx));
                            ushort parent_reg = self.alloc_reg();
                            self.emit_abc(Opcode.GETPROP, (uint)parent_reg, (uint)val_reg, (uint)parent_key_reg);
                            self.free_reg(parent_key_reg);

                            ushort inner_key_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)inner_key_reg, obj_binds[bi].nested_key_idx));
                            self.emit_abc(Opcode.GETPROP, (uint)obj_binds[bi].reg, (uint)parent_reg, (uint)inner_key_reg);
                            self.free_reg(inner_key_reg);
                            self.free_reg(parent_reg);
                        } else {
                            ushort key_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, obj_binds[bi].key_idx));
                            self.emit_abc(Opcode.GETPROP, (uint)obj_binds[bi].reg, (uint)val_reg, (uint)key_reg);
                            self.free_reg(key_reg);
                        }

                        if (obj_binds[bi].has_default) {
                            ushort undef_reg = self.alloc_reg();
                            self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                            ushort is_undef_reg = self.alloc_reg();
                            self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)obj_binds[bi].reg, (uint)undef_reg);
                            self.free_reg(undef_reg);
                            uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                            self.free_reg(is_undef_reg);
                            self.emit_abc(Opcode.LDREG, (uint)obj_binds[bi].reg, (uint)obj_binds[bi].default_val_reg, 0);
                            self.patch_jump(skip_default);
                            self.free_reg(obj_binds[bi].default_val_reg);
                        }

                        self.emit_var_store(obj_binds[bi].reg, obj_binds[bi].name_idx, is_lexical, is_const);
                    }
                }

                self.free_reg(val_reg);
                self.free_reg(value_key_reg);
                self.free_reg(done_reg);
                self.free_reg(done_key_reg);
                self.free_reg(result_reg);

                self.statement()!;

                self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;

                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                self.free_reg(callee_this_reg);
                self.free_reg(callee_reg);
                self.free_reg(next_reg);
                self.free_reg(method_reg);
                self.free_reg(iter_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            } else if (is_forin_destr) {
                // for-in with destructuring: for (let {x, y} in obj) or for (let [a, b] in obj)
                bool is_array_pattern = (after_decl == TokenType.LBRACKET);
                ushort obj_reg = 0;

                // ── Parse the destructuring pattern inline ──
                ArrayBind[32] fin_binds;
                ObjBind[32]   fobj_binds;
                uint fbind_count = 0;

                if (is_array_pattern) {
                    self.advance()!; // consume '['
                    for (;;) {
                        if (self.check(TokenType.RBRACKET)) break;

                        if (self.check(TokenType.COMMA)) {
                            self.advance()!;
                            if (fbind_count < 32) {
                                fin_binds[fbind_count].is_hole = true;
                                fin_binds[fbind_count].has_default = false;
                                fbind_count++;
                            }
                            continue;
                        }

                        if (self.match(TokenType.ELLIPSIS)) {
                            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
                            if (fbind_count < 32) {
                                ushort reg = self.declare_var(rest_tok.str_value, decl_kind);
                                fin_binds[fbind_count].reg = reg;
                                fin_binds[fbind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                                fin_binds[fbind_count].is_rest = true;
                                fin_binds[fbind_count].is_hole = false;
                                fin_binds[fbind_count].has_default = false;
                                fbind_count++;
                            }
                            while (self.match(TokenType.COMMA)) {}
                            break;
                        }

                        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
                        if (fbind_count < 32) {
                            ushort reg = self.declare_var(name_tok.str_value, decl_kind);
                            fin_binds[fbind_count].reg = reg;
                            fin_binds[fbind_count].name_idx = self.add_string_constant(name_tok.str_value);
                            fin_binds[fbind_count].is_rest = false;
                            fin_binds[fbind_count].is_hole = false;
                            fin_binds[fbind_count].has_default = false;

                            if (self.match(TokenType.ASSIGN)) {
                                fin_binds[fbind_count].has_default = true;
                                fin_binds[fbind_count].default_val_reg = self.assignment_expr()!;
                            }

                            fbind_count++;
                        }

                        if (!self.match(TokenType.COMMA)) break;
                    }
                    self.expect(TokenType.RBRACKET)!;
                } else {
                    // Object pattern
                    self.advance()!; // consume '{'
                    if (!self.check(TokenType.RBRACE)) {
                        for (;;) {
                            Token prop_tok = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;

                            if (self.match(TokenType.COLON)) {
                                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                                if (fbind_count < 32) {
                                    ushort reg = self.declare_var(bind_tok.str_value, decl_kind);
                                    fobj_binds[fbind_count].reg = reg;
                                    fobj_binds[fbind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                                    fobj_binds[fbind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                    fobj_binds[fbind_count].has_default = false;

                                    if (self.match(TokenType.ASSIGN)) {
                                        fobj_binds[fbind_count].has_default = true;
                                        fobj_binds[fbind_count].default_val_reg = self.assignment_expr()!;
                                    }

                                    fbind_count++;
                                }
                            } else {
                                // Shorthand: {name}
                                if (fbind_count < 32) {
                                    ushort reg = self.declare_var(prop_tok.str_value, decl_kind);
                                    fobj_binds[fbind_count].reg = reg;
                                    fobj_binds[fbind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                                    fobj_binds[fbind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                    fobj_binds[fbind_count].has_default = false;

                                    if (self.match(TokenType.ASSIGN)) {
                                        fobj_binds[fbind_count].has_default = true;
                                        fobj_binds[fbind_count].default_val_reg = self.assignment_expr()!;
                                    }

                                    fbind_count++;
                                }
                            }

                            if (!self.match(TokenType.COMMA)) break;
                        }
                    }
                    self.expect(TokenType.RBRACE)!;
                }

                self.expect(TokenType.IN)!;

                obj_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                }

                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                ushort key_reg = self.alloc_reg();
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)key_reg, (uint)has_next, (uint)iter_state);

                // Destructure the key string using property access
                // (for-in keys are always strings, which support numeric index access)
                if (is_array_pattern) {
                    for (uint bi = 0; bi < fbind_count; bi++) {
                        if (fin_binds[bi].is_hole) continue;

                        if (fin_binds[bi].is_rest) {
                            uint rest_idx = 0;
                            for (uint j = 0; j < bi; j++) {
                                if (!fin_binds[j].is_hole) rest_idx++;
                            }
                            ushort callee_reg = self.alloc_reg();
                            if (self.next_reg < callee_reg + 3) {
                                self.next_reg = callee_reg + 3;
                            }
                            ushort slice_key_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)slice_key_reg, self.add_string_constant("slice")));
                            ushort slice_method_reg = self.alloc_reg();
                            self.emit_abc(Opcode.GETPROP, (uint)slice_method_reg, (uint)key_reg, (uint)slice_key_reg);
                            self.free_reg(slice_key_reg);
                            self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)slice_method_reg, 0);
                            self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)key_reg, 0);
                            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)(callee_reg + 2), (int)rest_idx));
                            self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);
                            self.emit_abc(Opcode.LDREG, (uint)fin_binds[bi].reg, (uint)callee_reg, 0);
                            self.free_regs_to(callee_reg);
                        } else {
                            ushort idx_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)bi));
                            self.emit_abc(Opcode.GETPROP, (uint)fin_binds[bi].reg, (uint)key_reg, (uint)idx_reg);
                            self.free_reg(idx_reg);

                            if (fin_binds[bi].has_default) {
                                ushort undef_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                                ushort is_undef_reg = self.alloc_reg();
                                self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)fin_binds[bi].reg, (uint)undef_reg);
                                self.free_reg(undef_reg);
                                uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                                self.free_reg(is_undef_reg);
                                self.emit_abc(Opcode.LDREG, (uint)fin_binds[bi].reg, (uint)fin_binds[bi].default_val_reg, 0);
                                self.patch_jump(skip_default);
                                self.free_reg(fin_binds[bi].default_val_reg);
                            }
                        }

                        self.emit_var_store(fin_binds[bi].reg, fin_binds[bi].name_idx, is_lexical, is_const);
                    }
                } else {
                    for (uint bi = 0; bi < fbind_count; bi++) {
                        ushort key2_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key2_reg, fobj_binds[bi].key_idx));
                        self.emit_abc(Opcode.GETPROP, (uint)fobj_binds[bi].reg, (uint)key_reg, (uint)key2_reg);
                        self.free_reg(key2_reg);

                        if (fobj_binds[bi].has_default) {
                            ushort undef_reg = self.alloc_reg();
                            self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                            ushort is_undef_reg = self.alloc_reg();
                            self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)fobj_binds[bi].reg, (uint)undef_reg);
                            self.free_reg(undef_reg);
                            uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                            self.free_reg(is_undef_reg);
                            self.emit_abc(Opcode.LDREG, (uint)fobj_binds[bi].reg, (uint)fobj_binds[bi].default_val_reg, 0);
                            self.patch_jump(skip_default);
                            self.free_reg(fobj_binds[bi].default_val_reg);
                        }

                        self.emit_var_store(fobj_binds[bi].reg, fobj_binds[bi].name_idx, is_lexical, is_const);
                    }
                }

                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                self.statement()!;

                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                }

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            } else {
                // Standard for-loop with destructuring init: for (var [a,b] = ...; ...; ...)
                if (after_decl == TokenType.LBRACKET) {
                    self.advance()!; // consume '['
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    self.advance()!; // consume '{'
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                }

                // More declarations? (var [a]=x, b=y)
                while (self.match(TokenType.COMMA)) {
                    TokenType nt = self.peek_type();
                    if (nt == TokenType.LBRACKET) {
                        self.advance()!;
                        self.array_destructure(decl_kind, is_lexical, is_const)!;
                    } else if (nt == TokenType.LBRACE) {
                        self.advance()!;
                        self.object_destructure(decl_kind, is_lexical, is_const)!;
                    } else {
                        Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                        ushort extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                        if (self.match(TokenType.ASSIGN)) {
                            ushort extra_val = self.assignment_expr()!;
                            if (extra_val != extra_reg) {
                                self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                            }
                            self.free_reg(extra_val);
                        } else {
                            self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                        }
                        uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                        self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                    }
                }

                self.expect(TokenType.SEMICOLON)!;
            }
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;

            // Check for "in" (for-in) or "of" (for-of)
            if (self.peek_type() == TokenType.IN) {
                // for (let/const/var x in obj) { ... }
                self.advance()!;  // consume 'in'
                // Declare the for-in variable so let/const semantics
                // (write-protection, TDZ, duplicate detection) are enforced.
                // For lexical bindings, declare_var pushes a scope_stack entry
                // so the body can resolve the name via the scope chain.
                ushort iter_var = self.declare_var(name_tok.str_value, decl_kind);
                ushort obj_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                // For let/const, push a new lexical environment so the loop
                // variable is block-scoped (not visible outside the loop) and
                // closures inside the body capture from this lex_env.
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                }

                // Emit INITFOR to set up the iterator
                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                // Emit NEXTFOR: iter_var = next key, B = has_next
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);
                // Sync the for-in variable to the environment
                uint forin_name_idx = self.add_string_constant(name_tok.str_value);
                self.emit_var_store(iter_var, forin_name_idx, is_lexical, is_const);
                // No reload needed: DECLVAR/PUTLEX/PUTLEX_C do not clear the source
                // register, so iter_var still holds the current key after the store.

                // If no more keys, exit
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                // Compile body
                self.statement()!;

                // Jump back to loop start
                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                // Pop the lexical scope for let/const, removing the
                // block-scoped binding from the VM's lex_env chain.
                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                }

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            }
            // Check for "of" (for-of) — contextual keyword, not a reserved word
            if (try tok = self.lexer.peek()) {
                if (tok.type == TokenType.IDENTIFIER && str_eq(tok.str_value, "of")) {
                    self.advance()!;  // consume "of"
                    ushort iter_reg = self.assignment_expr()!;
                    self.expect(TokenType.RPAREN)!;
                    uint name_idx = self.add_string_constant(name_tok.str_value);
                    self.emit_forof_loop(name_tok.str_value, iter_reg, saved_scope, saved_reg, is_lexical, is_const, false)!;
                    return;
                }
            }

            // Standard for loop: we already consumed the decl keyword and identifier
            // Declare the variable and optionally initialize
            ushort var_reg = self.declare_var(name_tok.str_value, decl_kind);
            has_for_var = !is_lexical && !self.is_global;
            for_var_reg = var_reg;
            for_var_name_idx = self.add_string_constant(name_tok.str_value);
            if (is_lexical) { self.emit_simple(Opcode.PUSH_LEX); }
            if (self.match(TokenType.ASSIGN)) {
                ushort init_val = self.assignment_expr()!;
                if (init_val != var_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)var_reg, (uint)init_val, 0);
                }
                self.free_reg(init_val);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
            }
            // Also store in environment (needed at global scope for GETVAR)
            self.emit_var_store(var_reg, for_var_name_idx, is_lexical, is_const);

            // More declarations?
            while (self.match(TokenType.COMMA)) {
                TokenType nt2 = self.peek_type();
                if (nt2 == TokenType.LBRACKET) {
                    self.advance()!;
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else if (nt2 == TokenType.LBRACE) {
                    self.advance()!;
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                    ushort extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                    if (self.match(TokenType.ASSIGN)) {
                        ushort extra_val = self.assignment_expr()!;
                        if (extra_val != extra_reg) {
                            self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                        }
                        self.free_reg(extra_val);
                    } else {
                        self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                    }
                    uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                    self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                }
            }

            self.expect(TokenType.SEMICOLON)!;
        }
    } else if (next_tt != TokenType.SEMICOLON) {
        // Expression init
        ushort init_reg = self.expression()!;
        self.free_reg(init_reg);
        self.expect(TokenType.SEMICOLON)!;
    } else {
        // Empty init
        self.expect(TokenType.SEMICOLON)!;
    }

    // --- Rotated for-loop layout ---
    // Avoid running the condition before the first body iteration by rotating:
    //
    //   JUMP → cond_label            (executed once; provides zero-iteration check)
    //   body_label:
    //     <body>
    //   incr_label:                  ← continue targets here
    //     <increment>
    //   cond_label:
    //     <condition>  (IF_TRUE → body_label  — back edge)
    //   exit:                        ← break patches here
    //
    // With the JMP_LT/JMP_LE/JMP_GT/JMP_GE peephole, the per-iteration hot path
    // is: body → increment → LT + IF_TRUE → JMP_LT body_label ≈4 dispatches.
    //
    // Literal hoisting: for the common condition `<ident> <relop> <numeric literal>`,
    // we pre-load the literal into a pinned register before the initial JUMP.
    // This removes LDINT/LDCONST from the per-iteration hot path.
    //
    // Implementation: we save the lexer state at the condition and increment,
    // use a token-scanner (skip_expr_lex) to skip them without emitting code,
    // compile the body at body_label, then restore+compile increment at incr_label,
    // then restore+compile condition at cond_label with IF_TRUE → body_label.

    // ----------------------------------------------------------------
    // Step 0: Detect simple condition: IDENTIFIER <relop> NUMBER ;
    // ----------------------------------------------------------------

    uint  _cond_pos; uint  _cond_line; uint  _cond_col;
    Token _cond_cur; Token _cond_look; bool  _cond_haslk;
    Token _cond_push; bool _cond_haspb; bool _cond_slt;
    uint  _cond_pbc;  Token[4] _cond_pbs;
    _cond_pos   = self.lexer.pos;
    _cond_line  = self.lexer.line;
    _cond_col   = self.lexer.col;
    _cond_cur   = self.lexer.current;
    _cond_look  = self.lexer.lookahead;
    _cond_haslk = self.lexer.has_lookahead;
    _cond_push  = self.lexer.pushed_back;
    _cond_haspb = self.lexer.has_pushed_back;
    _cond_slt   = self.lexer.seen_line_term;
    _cond_pbc   = self.pushback_count;
    _cond_pbs   = self.pushback_stack;

    bool has_cond = !self.check(TokenType.SEMICOLON);

    // Detect `IDENTIFIER <relop> NUMBER ;` (only when pushback is empty)
    bool has_simple_cond = false;
    double simple_cond_rhs = 0.0;
    Opcode simple_cond_op = Opcode.LT;
    ushort pinned_rhs_reg = 0;

    // Use the captured state (_cond_haslk / _cond_haspb) rather than the current lexer
    // state: self.check() above calls lexer.peek() which sets has_lookahead as a side
    // effect, so testing self.lexer.has_lookahead here always returns true (false negative).
    if (has_cond && _cond_pbc == 0 && !_cond_haspb && !_cond_haslk) {
        Token? t1o = self.lexer.next_token();
        if (try t1 = t1o) {
            Token? t2o = self.lexer.next_token();
            if (try t2 = t2o) {
                Token? t3o = self.lexer.next_token();
                if (try t3 = t3o) {
                    Token? t4o = self.lexer.next_token();
                    if (try t4 = t4o) {
                        bool is_ident = (t1.type == TokenType.IDENTIFIER);
                        bool is_relop = (t2.type == TokenType.LT || t2.type == TokenType.LE
                                      || t2.type == TokenType.GT || t2.type == TokenType.GE);
                        bool is_num   = (t3.type == TokenType.NUMBER);
                        bool is_semi  = (t4.type == TokenType.SEMICOLON);
                        if (is_ident && is_relop && is_num && is_semi) {
                            has_simple_cond = true;
                            simple_cond_rhs = t3.num_value;
                            switch (t2.type) {
                                case TokenType.LT: simple_cond_op = Opcode.LT;
                                case TokenType.LE: simple_cond_op = Opcode.LE;
                                case TokenType.GT: simple_cond_op = Opcode.GT;
                                default:           simple_cond_op = Opcode.GE;
                            }
                        }
                    }
                }
            }
        }
        // Restore to before detection scan.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
    }

    // ----------------------------------------------------------------
    // Step 1: Pre-load the pinned RHS register (before initial JUMP).
    // ----------------------------------------------------------------
    if (has_simple_cond) {
        pinned_rhs_reg = self.alloc_reg();
        int int_rhs = (int)simple_cond_rhs;
        if ((double)int_rhs == simple_cond_rhs
            && int_rhs >= bytecode::MIN_SBC && int_rhs <= bytecode::MAX_SBC) {
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs));
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx));
        }
    }

    // ----------------------------------------------------------------
    // Step 2: Emit initial JUMP → cond_label and record body_label.
    // ----------------------------------------------------------------
    uint cond_jump = 0;
    bool has_empty_cond = !has_cond;
    if (!has_empty_cond) {
        cond_jump = self.emit_jump(Opcode.JUMP);  // forward → cond_label
    }
    uint body_label = self.code_count;

    // ----------------------------------------------------------------
    // Step 3: Skip condition tokens (no code emitted) using token scanner.
    // ----------------------------------------------------------------
    if (has_cond) {
        // skip_expr_lex scans until `;` or `)` at depth 0, leaving the terminator
        // in the lexer's pushed_back buffer.
        self.skip_expr_lex();
    }
    self.expect(TokenType.SEMICOLON)!;  // consume the `;` after condition

    // ----------------------------------------------------------------
    // Step 4: Save lexer state for increment, then skip it.
    // ----------------------------------------------------------------
    uint  _incr_pos; uint  _incr_line; uint  _incr_col;
    Token _incr_cur; Token _incr_look; bool  _incr_haslk;
    Token _incr_push; bool _incr_haspb; bool _incr_slt;
    uint  _incr_pbc;  Token[4] _incr_pbs;
    _incr_pos   = self.lexer.pos;   _incr_line  = self.lexer.line;   _incr_col   = self.lexer.col;
    _incr_cur   = self.lexer.current; _incr_look  = self.lexer.lookahead;
    _incr_haslk = self.lexer.has_lookahead; _incr_push  = self.lexer.pushed_back;
    _incr_haspb = self.lexer.has_pushed_back; _incr_slt = self.lexer.seen_line_term;
    _incr_pbc   = self.pushback_count; _incr_pbs   = self.pushback_stack;

    bool has_incr = !self.check(TokenType.RPAREN);
    if (has_incr) {
        self.skip_expr_lex();
    }
    self.expect(TokenType.RPAREN)!;   // consume `)` after increment

    // ----------------------------------------------------------------
    // Step 5: Push loop and compile body.
    // ----------------------------------------------------------------
    // continue_target placeholder = body_label; updated to incr_label after body.
    self.push_loop(body_label, true);
    self.statement()!;

    // Save the lexer state after the body — this is where the outer parser
    // must resume after for_statement returns.  Steps 6 and 7 will restore
    // lexer state for re-compilation; we restore to here at the very end.
    uint  _post_pos; uint  _post_line; uint  _post_col;
    Token _post_cur; Token _post_look; bool  _post_haslk;
    Token _post_push; bool _post_haspb; bool _post_slt;
    uint  _post_pbc;  Token[4] _post_pbs;
    _post_pos   = self.lexer.pos;   _post_line  = self.lexer.line;   _post_col   = self.lexer.col;
    _post_cur   = self.lexer.current; _post_look  = self.lexer.lookahead;
    _post_haslk = self.lexer.has_lookahead; _post_push  = self.lexer.pushed_back;
    _post_haspb = self.lexer.has_pushed_back; _post_slt = self.lexer.seen_line_term;
    _post_pbc   = self.pushback_count; _post_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 6: incr_label — patch continue_target, then compile increment.
    // ----------------------------------------------------------------
    uint incr_label = self.code_count;
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = incr_label;
    }

    if (has_incr) {
        self.lexer.pos = _incr_pos; self.lexer.line = _incr_line; self.lexer.col = _incr_col;
        self.lexer.current = _incr_cur; self.lexer.lookahead = _incr_look;
        self.lexer.has_lookahead = _incr_haslk; self.lexer.pushed_back = _incr_push;
        self.lexer.has_pushed_back = _incr_haspb; self.lexer.seen_line_term = _incr_slt;
        self.pushback_count = _incr_pbc; self.pushback_stack = _incr_pbs;
        ushort incr_reg = self.expression()!;
        self.free_reg(incr_reg);
    }

    // Sync register-cached for-init var back to the environment when necessary.
    // Closures/direct-eval inside the loop can observe the binding each iteration,
    // so keep it up to date. Otherwise the variable lives purely in its register
    // for the loop's duration, which avoids the expensive PUTVAR/GETVAR pair.
    bool for_var_needs_iter_sync = has_for_var && (self.has_closures || self.has_direct_eval);
    if (for_var_needs_iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }

    // ----------------------------------------------------------------
    // Step 7: cond_label — patch initial JUMP, compile condition with IF_TRUE back edge.
    // ----------------------------------------------------------------
    if (!has_empty_cond) {
        self.patch_jump(cond_jump);
    }

    if (!has_empty_cond) {
        if (has_simple_cond) {
            // Re-compile condition from saved lexer state, using pinned_rhs_reg.
            self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
            self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
            self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
            self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
            self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
            Token ident_tok = self.advance()!;
            Token _relop    = self.advance()!;  // consume relop
            Token _num_tok  = self.advance()!;  // consume NUMBER (value already in pinned_rhs_reg)
            self.expect(TokenType.SEMICOLON)!;  // consume `;`

            ushort lhs_reg = self.alloc_reg();
            // Mirror primary_expr: at global scope, all identifiers go through GETVAR
            // (registers are not kept in sync with the env by the body). resolve_var is
            // only safe when the body also uses the register directly (non-global scope).
            if (!self.is_global) {
                if (try reg = self.resolve_var(ident_tok.str_value)) {
                    if (reg != lhs_reg) {
                        self.emit_abc(Opcode.LDREG, (uint)lhs_reg, (uint)reg, 0);
                    }
                } else {
                    uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                    self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
                }
            } else {
                uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
            }
            ushort cmp_res = self.alloc_reg();
            self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
            self.free_reg(lhs_reg);
            int back = (int)body_label - (int)self.code_count - 1;
            self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_res, back));
            self.free_reg(cmp_res);
            self.free_reg(pinned_rhs_reg);
        } else {
            // General condition: restore and re-compile normally.
            self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
            self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
            self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
            self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
            self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
            ushort cond_reg = self.expression()!;
            self.expect(TokenType.SEMICOLON)!;
            int back = (int)body_label - (int)self.code_count - 1;
            self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back));
            self.free_reg(cond_reg);
        }
    } else {
        // for(;;) — unconditional back edge
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, back));
    }

    // exit: pop_loop patches all break jumps to current position.
    self.pop_loop();
    if (is_lexical) { self.emit_simple(Opcode.POP_LEX); }

    // For uncaptured for-init vars the environment was not updated each
    // iteration, so write the final register value once before the register
    // is freed and subsequent code reads the binding via GETVAR.
    if (has_for_var && !for_var_needs_iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
    }

    // Restore the lexer to the position after the body so the outer parser
    // continues from the right source position.
    self.lexer.pos = _post_pos; self.lexer.line = _post_line; self.lexer.col = _post_col;
    self.lexer.current = _post_cur; self.lexer.lookahead = _post_look;
    self.lexer.has_lookahead = _post_haslk; self.lexer.pushed_back = _post_push;
    self.lexer.has_pushed_back = _post_haspb; self.lexer.seen_line_term = _post_slt;
    self.pushback_count = _post_pbc; self.pushback_stack = _post_pbs;

    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Parse do-while statement.
fn void? CompilerContext.do_while_statement(&self) {
    self.expect(TokenType.DO)!;

    uint loop_start = self.code_count;
    // Continue target is the condition (we'll record the address after the body)
    self.push_loop(loop_start, true);  // temporary; we'll fix continue_target

    // Compile body
    self.statement()!;

    // Fix the continue target to point to the condition
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    }

    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.match(TokenType.SEMICOLON);

    // If condition is true, jump back to loop_start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back_offset));
    self.free_reg(cond_reg);

    self.pop_loop();
}

/// Parse return statement.
fn void? CompilerContext.return_statement(&self) {
    self.expect(TokenType.RETURN)!;

    // Check if there's a return value (not a semicolon or end-of-statement)
    // A line terminator between return and the expression causes ASI (ES5 §12.9)
    TokenType next = self.peek_type();
    if (next == TokenType.SEMICOLON || next == TokenType.RBRACE ||
        next == TokenType.EOF_TOKEN || self.lexer.seen_line_term) {
        self.emit_simple((self.is_generator && !self.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    } else {
        ushort val_reg = self.expression()!;
        self.emit_abc((self.is_generator && !self.is_async) ? Opcode.RET_GEN : Opcode.RET, (uint)val_reg, 0, 0);
        // Note: do NOT free_reg(val_reg) here.  The return value register may
        // be a live local variable (e.g. `return i` inside a for-loop body).
        // Calling free_reg would let the allocator reuse it for subsequent
        // code (the loop increment/condition), clobbering the variable.
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse throw statement.
fn void? CompilerContext.throw_statement(&self) {
    self.expect(TokenType.THROW)!;

    ushort val_reg = self.expression()!;
    self.emit_abc(Opcode.THROW, (uint)val_reg, 0, 0);
    // Note: do NOT free_reg(val_reg) here, same reason as return_statement.

    self.match(TokenType.SEMICOLON);
}

/// Parse try/catch/finally statement.
///
/// Bytecode layout:
///   TRY A=flags, BC=catch_offset     — A bit0=catch, bit1=finally
///   NOP A=0,    BC=finally_offset    — jump slot (0 if no finally)
///   <try block>
///   ENDTRY
///   JUMP -> finally_or_after
///   [CATCH rX  — at try_addr + catch_offset]
///   [<catch block>]
///   [FINALLY   — at try_addr + finally_offset (if has_finally)]
///   [<finally block>]
///   [ENDFINALLY]
fn void? CompilerContext.try_statement(&self) {
    self.expect(TokenType.TRY)!;

    // Emit TRY instruction (placeholder: A=0, BC=0, jump_slot BC=0)
    uint try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
    // Jump slot — the VM reads this word for the finally_offset (BC field)
    uint jump_slot_addr = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Push try info
    if (self.try_depth < MAX_TRY_DEPTH) {
        self.try_stack[self.try_depth].catch_addr = try_addr;
        self.try_stack[self.try_depth].finally_addr = NO_PATCH;
        self.try_depth++;
    }

    // Compile try block
    self.block(false)!;

    // Emit ENDTRY to pop the try handler (normal exit)
    self.emit_simple(Opcode.ENDTRY);

    // Jump (skips catch handler; target patched later)
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // catch handler starts here
    uint catch_target = self.code_count;

    // Parse catch clause
    bool has_catch = false;
    bool has_finally = false;
    uint finally_tgt = 0;

    if (self.match(TokenType.CATCH)) {
        has_catch = true;
        uint catch_scope = self.scope_depth;
        ushort catch_saved_reg = self.next_reg;

        if (self.match(TokenType.LPAREN)) {
            Token catch_param = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(catch_param.str_value)) {
                return COMPILE_ERROR~;
            }
            self.expect(TokenType.RPAREN)!;

            ushort catch_var = self.declare_var(catch_param.str_value, VAR);
            // Force the catch variable through the environment (GETVAR/PUTVAR)
            // instead of direct register access.  PUTVAR clears the source
            // register after storing to the env (for refcount correctness),
            // so a later register read would get undefined.
            if (!self.is_global && self.scope_depth > 0) {
                self.scope_stack[self.scope_depth - 1].is_captured = true;
            }
            self.emit_abc(Opcode.CATCH, (uint)catch_var, 0, 0);
            // PUTVAR the exception into the env so that subsequent
            // GETVAR/TYPEOFIDENT for the catch variable finds it.
            // Required in ALL scopes (not just global) because the VM
            // resolves catch variables via environment lookup, not register.
            {
                uint name_idx = self.add_string_constant(catch_param.str_value);
                self.emit_a_bc(Opcode.PUTVAR, (uint)catch_var, name_idx);
            }
        } else {
            // catch without binding (ES2019)
            ushort discard = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)discard, 0, 0);
            self.free_reg(discard);
        }

        // Compile catch block
        self.block(false)!;

        self.pop_scope_to(catch_scope);
        self.free_regs_to(catch_saved_reg);
    }

    // Parse finally clause
    if (self.match(TokenType.FINALLY)) {
        has_finally = true;
        finally_tgt = self.code_count;

        // Patch the jump from the try block to land at FINALLY
        self.patch_jump(jump_over);

        // Emit FINALLY marker
        self.emit_simple(Opcode.FINALLY);

        // Compile finally block
        self.block(false)!;

        // Emit ENDFINALLY
        self.emit_simple(Opcode.ENDFINALLY);
    } else {
        // Patch jump to skip catch handler
        self.patch_jump(jump_over);
    }

    // Patch TRY instruction: A=flags, BC=catch_offset
    uint try_flags = (has_catch ? 1u : 0u) | (has_finally ? 2u : 0u);
    uint catch_offset = catch_target - try_addr;
    self.code[try_addr] = bytecode::make_a_bc(Opcode.TRY, try_flags, catch_offset);

    // Patch jump slot: BC=finally_offset (0 if no finally)
    uint finally_off = has_finally ? (finally_tgt - try_addr) : 0;
    self.code[jump_slot_addr] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);

    // Pop try info
    if (self.try_depth > 0) {
        self.try_depth--;
    }
}

/// Parse switch statement with correct fall-through (ES5 §12.11).
///
/// Each case body ends with a fall-through redirect JUMP patched after all
/// case clauses are parsed, so that when a matched case body completes (without
/// break) execution continues to the next case body rather than re-checking
/// the next case's comparison preamble. The `default` clause is handled with
/// a preamble JUMP when it is not the last clause, allowing subsequent cases
/// to be checked before falling through to default on no match.
fn void? CompilerContext.switch_statement(&self) {
    self.expect(TokenType.SWITCH)!;
    self.expect(TokenType.LPAREN)!;

    ushort disc_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.expect(TokenType.LBRACE)!;

    // Push a "loop" for break handling (break in switch exits the switch)
    // is_loop=false so continue skips this entry.
    self.push_loop(self.code_count, false);

    // Track all body entries (cases and default) in source order
    uint[64] body_addrs;
    uint[64] ft_jump_addrs;
    uint body_count = 0;
    bool has_default = false;
    uint default_body_idx = 0;
    bool default_not_last = false;

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        if (self.match(TokenType.CASE)) {
            // Compile case expression
            ushort case_reg = self.expression()!;
            self.expect(TokenType.COLON)!;

            // Compare discriminant with case value
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)disc_reg, (uint)case_reg);
            self.free_reg(case_reg);

            // Jump to the case body if they match
            uint match_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

            // Jump over the body if no match
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch the match jump to here (the body)
            self.patch_jump(match_jump);
            body_addrs[body_count] = self.code_count;

            // Compile case body statements
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect jump (patched later to next body)
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Patch skip jump to after the fall-through redirect
            self.patch_jump(skip_jump);

        } else if (self.match(TokenType.DEFAULT)) {
            self.expect(TokenType.COLON)!;

            has_default = true;
            default_body_idx = body_count;

            // Emit preamble JUMP over default body (placeholder).
            // If more clauses follow, this skips the default body for the
            // case-checking path. If default is last, it becomes a no-op.
            uint default_preamble = self.emit_jump(Opcode.JUMP);

            body_addrs[body_count] = self.code_count;

            // Compile default body
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect for default
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Check if anything follows this default clause
            TokenType next = self.peek_type();
            if (next == TokenType.CASE || next == TokenType.DEFAULT) {
                // More clauses follow: preamble skips over default body
                self.patch_jump(default_preamble);
                default_not_last = true;
            } else {
                // Default is last: patch preamble to fall through to body
                // (offset 0 = jump to next instruction = body start)
                int ft_offset = (int)(body_addrs[default_body_idx]) -
                                (int)(default_preamble) - 1;
                self.code[default_preamble] =
                    bytecode::make_sabc(Opcode.JUMP, ft_offset);
            }
        } else {
            // Unexpected token in switch
            return COMPILE_ERROR~;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // If default is not last, emit a redirect for the 'no match' path at the
    // end of all case checks. This is reached by the last case's skip_jump.
    uint redirect_addr = 0;
    if (has_default && default_not_last) {
        redirect_addr = self.code_count;
        uint jump = self.emit_jump(Opcode.JUMP);
        // break jumps will be patched past this redirect by pop_loop
    }

    // Patch break jumps to end of switch (after redirect if any)
    self.pop_loop();

    uint end_addr = self.code_count;

    // Patch the 'no match' redirect to the default body
    if (redirect_addr > 0) {
        int offset = (int)(body_addrs[default_body_idx]) -
                     (int)(redirect_addr) - 1;
        self.code[redirect_addr] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    // Patch all fall-through redirect jumps in source order
    for (uint i = 0; i < body_count; i++) {
        uint target;
        if (i + 1 < body_count) {
            // Fall through to next body in source order
            target = body_addrs[i + 1];
        } else {
            // Last body: fall through to end of switch
            target = end_addr;
        }
        int offset = (int)(target) - (int)(ft_jump_addrs[i]) - 1;
        self.code[ft_jump_addrs[i]] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    self.free_reg(disc_reg);
}

/// Parse a labeled statement: `identifier : statement`.
/// Supports labeled break and continue (ES5 §12.12).
fn void? CompilerContext.labeled_statement(&self, char[] name) {
    // Check for duplicate labels
    for (uint i = 0; i < self.label_count; i++) {
        if (str_eq(self.labels[i].name, name)) {
            return COMPILE_ERROR~;
        }
    }

    // Register the label
    uint label_idx = self.label_count;
    if (label_idx >= MAX_LABELS) return COMPILE_ERROR~;
    self.labels[label_idx].name = name;
    self.label_count++;

    // Look ahead to determine if the inner statement is a loop
    TokenType next = self.peek_type();

    if (next == TokenType.FOR || next == TokenType.WHILE || next == TokenType.DO) {
        // The label refers to a loop. The loop will be pushed at index
        // self.loop_depth (the current depth before the loop's push_loop).
        self.labels[label_idx].loop_index = self.loop_depth;
        self.labels[label_idx].is_loop = true;
        self.statement()!;
    } else {
        // Non-loop label — push a virtual loop entry so break can target it.
        self.push_loop(self.code_count, false);
        self.labels[label_idx].loop_index = self.loop_depth - 1;
        self.labels[label_idx].is_loop = false;
        self.statement()!;
        self.pop_loop(); // patches all breaks targeting this label
    }
}

/// Parse break statement.
/// If an identifier follows `break`, it's a labeled break (ES5 §12.12).
/// A line terminator between `break` and the identifier means unlabeled break.
fn void? CompilerContext.break_statement(&self) {
    self.expect(TokenType.BREAK)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled break — find the label and add jump to its loop's break chain
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                uint loop_idx = self.labels[i].loop_index;
                uint jump_addr = self.emit_jump(Opcode.BREAK);
                self.loop_stack[loop_idx].break_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].break_patch_head, jump_addr);
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled break — break out of the innermost loop or switch
    uint jump_addr = self.emit_jump(Opcode.BREAK);
    self.add_break_patch(jump_addr);

    self.match(TokenType.SEMICOLON);
}

/// Parse continue statement.
/// If an identifier follows `continue`, it's a labeled continue (ES5 §12.12).
/// A line terminator between `continue` and the identifier means unlabeled continue.
fn void? CompilerContext.continue_statement(&self) {
    self.expect(TokenType.CONTINUE)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled continue — find the label and jump to its loop's continue target
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                if (!self.labels[i].is_loop) {
                    // continue on a non-loop label is a syntax error
                    return COMPILE_ERROR~;
                }
                uint loop_idx = self.labels[i].loop_index;
                // Use deferred patching so the continue target can be updated
                // after the body is compiled (needed for rotated for-loops where
                // continue_target is set to incr_label after body compilation).
                uint jump_addr = self.emit_jump(Opcode.CONTINUE);
                self.loop_stack[loop_idx].continue_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled continue — jump to continue target of the innermost *real* loop
    // (skip switch pseudo-loops that only handle break)
    int loop_idx = (int)self.loop_depth - 1;
    while (loop_idx >= 0 && !self.loop_stack[loop_idx].is_loop) {
        loop_idx--;
    }
    if (loop_idx >= 0) {
        // Emit placeholder jump and add to continue_patch_head for deferred patching
        uint jump_addr = self.emit_jump(Opcode.CONTINUE);
        self.loop_stack[loop_idx].continue_patch_head =
            self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
    } else {
        return COMPILE_ERROR~;
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse expression statement.
fn void? CompilerContext.expression_statement(&self) {
    ushort reg = self.expression()!;
    if (self.eval_mode) {
        // Preserve the expression result for eval's implicit return value
        self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)reg, 0);
    }
    self.free_reg(reg);
    self.match(TokenType.SEMICOLON);
}

/// Parse a function declaration (hoisted).
/// This is called during normal statement parsing for function declarations
/// that were NOT hoisted during the pre-scan phase.
fn void? CompilerContext.function_declaration(&self) {
    self.expect(TokenType.FUNCTION)!;

    // Check if this function declaration was already hoisted during pre-scan
    // If so, skip it entirely to avoid duplicate compilation.
    // For global scope, check against hoisted_fn_names
    if (self.is_global) {
        // Extract function name from current lexer position
        Token? star_opt = self.lexer.next_token();
        if (catch _err2 = star_opt) return;
        if (star_opt.type == TokenType.STAR) {
            // Generator function - put star back and continue
            self.lexer.pushback(star_opt);
        } else {
            // Not a star - put it back (it's the function name)
            self.lexer.pushback(star_opt);
        }
        Token? name_opt = self.lexer.next_token();
        if (catch _err = name_opt) return;
        if (name_opt.type == TokenType.IDENTIFIER) {
            char[] fn_name = name_opt.str_value;
            if (fn_name.len > 0) {
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
                    return;
                }
            }
        }
        // Put back the name token for normal processing
        self.lexer.pushback(name_opt);
    }

    // Function declarations are hoisted to function scope — need env.
    self.has_local_bindings = true;

    // Save and reset generator state: nested function declarations
    // inside a generator do not inherit the generator flag.
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Save and reset async state: nested function declarations
    // inside an async function do not inherit the async flag.
    bool saved_is_async = self.is_async;
    self.is_async = false;

    // Check for generator star: function* name() {}
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
    }

    Token name_tok = self.expect(TokenType.IDENTIFIER)!;
    ushort func_reg = self.declare_var(name_tok.str_value, VAR);

    // Compile the function into a nested CompiledFunction.
    // Restore is_async so compile_inner_function propagates the flag,
    // then immediately reset to prevent nested functions from inheriting it.
    self.is_async = saved_is_async;
    CompiledFunction* inner = self.compile_inner_function(name_tok.str_value)!;
    self.is_async = false;

    // Restore generator flag (async already reset above)
    self.is_generator = saved_is_generator;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
        self.has_closures = true;
    }

    // Emit CLOSURE to create the function object
    self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);

    // Declare the binding in the immediate var_env so inner functions can find it via GETVAR
    uint name_idx = self.add_string_constant(name_tok.str_value);
    self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);

    // At global scope, free the register — the function object lives in the
    // environment via GETVAR/PUTVAR, not in a register-cached scope slot.
    if (self.is_global) {
        self.free_reg(func_reg);
    }
}

// ============================================================================
// ESM Import/Export declarations
// ============================================================================

/// Get the CompModuleDef* from the opaque current_module pointer.
/// Returns null if not in module mode.
fn CompModuleDef* CompilerContext.get_module_def(&self) {
    return (CompModuleDef*)self.current_module;
}

/// Expect the contextual keyword `from` (not a reserved word — must be
/// checked as an identifier with value "from").
fn void? CompilerContext.expect_from(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (!str_eq(tok.str_value, "from")) {
        return COMPILE_ERROR~;
    }
}

/// Match the contextual keyword `from` — consumes and returns true if the
/// current token is the identifier "from".
fn bool CompilerContext.match_from(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    // Peek at the actual token to check the string value
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (str_eq(tok.str_value, "from")) {
        return true;
    }
    // Not 'from' — push back
    self.lexer.pushback(tok);
    return false;
}

/// Expect the contextual keyword `as`.
fn void? CompilerContext.expect_as(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (!str_eq(tok.str_value, "as")) {
        return COMPILE_ERROR~;
    }
}

/// Match the contextual keyword `as`.
fn bool CompilerContext.match_as(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (str_eq(tok.str_value, "as")) {
        return true;
    }
    self.lexer.pushback(tok);
    return false;
}

/// Parse an ESM import declaration (ES6 §15.2.2).
///
/// Forms:
///   import 'module'
///   import defaultName from 'module'
///   import { a, b as c } from 'module'
///   import * as ns from 'module'
///   import defaultName, { a } from 'module'
///   import defaultName, * as ns from 'module'
fn void? CompilerContext.import_declaration(&self) {
    if (!self.is_module) {
        io::eprintfn("import declarations are only allowed in modules");
        return COMPILE_ERROR~;
    }

    self.expect(TokenType.IMPORT)!;

    if (self.current_module == null) return COMPILE_ERROR~;
    CompModuleDef* mod = self.get_module_def();

    TokenType tt = self.peek_type();

    // Side-effect import: import 'module'
    if (tt == TokenType.STRING) {
        Token spec_tok = self.advance()!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // import defaultName ...
    bool has_default = false;
    char[] default_local = {};
    if (tt == TokenType.IDENTIFIER) {
        Token name_tok = self.advance()!;
        default_local = name_tok.str_value;
        has_default = true;

        if (self.peek_type() == TokenType.COMMA) {
            self.advance()!; // consume ','
        } else {
            // Must be: import defaultName from 'module'
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
            mod_register_import(mod, default_local, "default", req_idx, false, true);
            self.match(TokenType.SEMICOLON);
            return;
        }
    }

    tt = self.peek_type();

    // import * as ns from 'module'
    if (tt == TokenType.STAR) {
        self.advance()!; // consume '*'
        self.expect_as()!;
        Token ns_tok = self.expect(TokenType.IDENTIFIER)!;
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        mod_register_import(mod, ns_tok.str_value, "*", req_idx, true, false);
        if (has_default) {
            mod_register_import(mod, default_local, "default", req_idx, false, true);
        }
        self.match(TokenType.SEMICOLON);
        return;
    }

    // import { a, b as c } from 'module'
    if (tt == TokenType.LBRACE) {
        self.advance()!; // consume '{'

        // We need to collect specifiers first, then get the module specifier,
        // then emit bindings. Parse the specifier string first by peeking ahead.
        // Actually, we need the req_idx first. Let's parse specifiers into temp arrays.
        char[][32] local_names;
        char[][32] import_names;
        uint binding_count = 0;

        while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
            if (binding_count >= 32) return COMPILE_ERROR~;

            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.match_as()) {
                Token alias_tok = self.expect(TokenType.IDENTIFIER)!;
                local_names[binding_count] = alias_tok.str_value;
                import_names[binding_count] = name_tok.str_value;
            } else {
                local_names[binding_count] = name_tok.str_value;
                import_names[binding_count] = name_tok.str_value;
            }
            binding_count++;

            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);

        // Register import metadata (bindings are created at link time by execute_module)
        for (uint i = 0; i < binding_count; i++) {
            mod_register_import(mod, local_names[i], import_names[i], req_idx, false, false);
        }

        if (has_default) {
            mod_register_import(mod, default_local, "default", req_idx, false, true);
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    return COMPILE_ERROR~;
}

/// Parse an ESM export declaration (ES6 §15.2.3).
///
/// Forms:
///   export function foo() {}
///   export class Foo {}
///   export const/let/var x = ...
///   export { a, b as c }
///   export { a } from './other'
///   export * from './other'
///   export * as ns from './other'
///   export default function() {}
///   export default <expr>
///   export default class {}
fn void? CompilerContext.export_declaration(&self) {
    if (!self.is_module) {
        io::eprintfn("export declarations are only allowed in modules");
        return COMPILE_ERROR~;
    }

    self.expect(TokenType.EXPORT)!;

    if (self.current_module == null) return COMPILE_ERROR~;
    CompModuleDef* mod = self.get_module_def();

    TokenType tt = self.peek_type();

    // export default ...
    if (tt == TokenType.DEFAULT) {
        self.advance()!; // consume 'default'
        TokenType next = self.peek_type();

        // export default function() {} or export default function name() {}
        if (next == TokenType.FUNCTION) {
            self.advance()!; // consume 'function'
            bool is_gen = self.match(TokenType.STAR);
            if (is_gen) self.is_generator = true;

            // Check for named function expression
            char[] fn_name;
            if (self.peek_type() == TokenType.IDENTIFIER) {
                Token name_tok = self.advance()!;
                fn_name = name_tok.str_value;
            } else {
                fn_name = "*default*";
            }

            bool saved_is_async = self.is_async;
            self.is_async = false;
            CompiledFunction* inner = self.compile_inner_function(fn_name)!;
            self.is_async = saved_is_async;
            self.is_generator = false;

            uint inner_idx = 0;
            if (self.inner_func_count < MAX_INNER_FUNCS) {
                inner_idx = self.inner_func_count;
                self.inner_funcs[inner_idx] = inner;
                self.inner_func_count++;
                self.has_closures = true;
            }

            ushort func_reg = self.declare_var("*default*", VAR);
            self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
            uint name_idx = self.add_string_constant("*default*");
            self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);
            if (self.is_global) self.free_reg(func_reg);

            mod_register_export(mod, "*default*", "default", false, 0);
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default class {} or export default class Foo {}
        if (next == TokenType.CLASS) {
            // Parse class and assign to *default*
            self.class_declaration()!;
            mod_register_export(mod, "*default*", "default", false, 0);
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default <expr>
        ushort val_reg = self.assignment_expr()!;
        uint def_name_idx = self.add_string_constant("*default*");
        self.emit_a_bc(Opcode.DECLVAR, (uint)val_reg, def_name_idx);
        self.free_reg(val_reg);
        mod_register_export(mod, "*default*", "default", false, 0);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export * from './other'
    if (tt == TokenType.STAR) {
        self.advance()!; // consume '*'

        // export * as ns from './other'
        if (self.match_as()) {
            Token ns_tok = self.expect(TokenType.IDENTIFIER)!;
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
            mod_register_export(mod, "*", ns_tok.str_value, true, req_idx);
            self.match(TokenType.SEMICOLON);
            return;
        }

        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        mod_register_star_export(mod, req_idx);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export { a, b as c } or export { a } from './other'
    if (tt == TokenType.LBRACE) {
        self.advance()!; // consume '{'

        char[][32] local_names;
        char[][32] export_names;
        uint count = 0;

        while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
            if (count >= 32) return COMPILE_ERROR~;
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.match_as()) {
                Token alias_tok = self.expect(TokenType.IDENTIFIER)!;
                local_names[count] = name_tok.str_value;
                export_names[count] = alias_tok.str_value;
            } else {
                local_names[count] = name_tok.str_value;
                export_names[count] = name_tok.str_value;
            }
            count++;
            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;

        // Check for 'from' clause (indirect export)
        if (self.match_from()) {
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
            for (uint i = 0; i < count; i++) {
                mod_register_export(mod, local_names[i], export_names[i], true, req_idx);
            }
        } else {
            // Local export: the names are local bindings
            for (uint i = 0; i < count; i++) {
                mod_register_export(mod, local_names[i], export_names[i], false, 0);
            }
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    // export function foo() {}
    if (tt == TokenType.FUNCTION) {
        self.advance()!; // consume 'function'
        bool is_gen = self.match(TokenType.STAR);
        if (is_gen) self.is_generator = true;

        bool saved_is_async = self.is_async;
        self.is_async = false;

        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        ushort func_reg = self.declare_var(name_tok.str_value, VAR);

        CompiledFunction* inner = self.compile_inner_function(name_tok.str_value)!;
        self.is_async = saved_is_async;
        self.is_generator = false;

        uint inner_idx = 0;
        if (self.inner_func_count < MAX_INNER_FUNCS) {
            inner_idx = self.inner_func_count;
            self.inner_funcs[inner_idx] = inner;
            self.inner_func_count++;
            self.has_closures = true;
        }

        self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
        uint name_idx = self.add_string_constant(name_tok.str_value);
        self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);
        if (self.is_global) self.free_reg(func_reg);

        mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export class Foo {}
    if (tt == TokenType.CLASS) {
        // class_declaration() expects CLASS already consumed, but we need the name first.
        // Read the name, then put tokens back and call class_declaration().
        // Peek ahead for the class name
        Token saved_class = self.advance()!; // consume CLASS
        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        // Put both back so class_declaration can re-consume them
        self.lexer.pushback(name_tok);
        self.lexer.pushback(saved_class);
        self.class_declaration()!;
        mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export const/let/var x = ...
    if (tt == TokenType.VAR || tt == TokenType.LET || tt == TokenType.CONST) {
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
        ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

        if (!is_lexical) {
            self.has_local_bindings = true;
        }

        for (;;) {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) {
                return COMPILE_ERROR~;
            }

            ushort reg;
            if (!is_lexical) {
                ushort? existing = self.resolve_var(name_tok.str_value);
                if (try er = existing) {
                    reg = er;
                } else {
                    reg = self.declare_var(name_tok.str_value, kind);
                }
            } else {
                reg = self.declare_var(name_tok.str_value, kind);
            }

            if (self.match(TokenType.ASSIGN)) {
                ushort val_reg = self.assignment_expr()!;
                if (val_reg != reg) {
                    self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                }
                self.free_reg(val_reg);
            } else {
                if (is_const) return COMPILE_ERROR~;
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }

            uint name_idx = self.add_string_constant(name_tok.str_value);
            self.emit_var_store(reg, name_idx, is_lexical, is_const);
            if (self.is_global) self.free_reg(reg);

            mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0);

            if (!self.match(TokenType.COMMA)) break;
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    io::eprintfn("unsupported export form");
    return COMPILE_ERROR~;
}
