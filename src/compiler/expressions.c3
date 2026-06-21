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
// Expression parsing
// ============================================================================

/// Parse a full expression (comma operator at lowest precedence).
fn ushort? CompilerContext.expression(&self) {
    ushort result = self.assignment_expr()!;

    // Handle comma operator: evaluate each, keep last
    while (self.match(TokenType.COMMA)) {
        self.free_reg(result);
        result = self.assignment_expr()!;
    }

    return result;
}

/// Parse an assignment expression.
fn ushort? CompilerContext.assignment_expr(&self) {
    // Check for destructuring assignment: [a, b] = expr or {x, y} = expr
    TokenType first_tt = self.peek_type();
    if (first_tt == TokenType.LBRACKET || first_tt == TokenType.LBRACE) {
        bool is_array = (first_tt == TokenType.LBRACKET);

        // Save lexer state to look ahead for '=' after the pattern
        uint _pos   = self.lexer.pos;
        uint _line  = self.lexer.line;
        uint _col   = self.lexer.col;
        Token _cur  = self.lexer.current;
        Token _look = self.lexer.lookahead;
        bool _haslk = self.lexer.has_lookahead;
        Token _push = self.lexer.pushed_back;
        bool _haspb = self.lexer.has_pushed_back;
        bool _slt   = self.lexer.seen_line_term;
        uint _pbc   = self.pushback_count;
        Token[4] _pbs = self.pushback_stack;

        // Skip past the pattern (match brackets/braces at any depth)
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

        // Check if '=' follows the pattern
        bool has_assign = self.match(TokenType.ASSIGN);

        // Restore lexer state
        self.lexer.pos = _pos; self.lexer.line = _line; self.lexer.col = _col;
        self.lexer.current = _cur; self.lexer.lookahead = _look;
        self.lexer.has_lookahead = _haslk; self.lexer.pushed_back = _push;
        self.lexer.has_pushed_back = _haspb; self.lexer.seen_line_term = _slt;
        self.pushback_count = _pbc; self.pushback_stack = _pbs;

        if (has_assign) {
            // Destructuring assignment — parse pattern and RHS
            self.last_was_getvar = false;
            self.last_was_member = false;

            if (is_array) {
                self.advance()!; // consume '['
                return self.array_destructure_assign()!;
            } else {
                self.advance()!; // consume '{'
                return self.object_destructure_assign()!;
            }
        }
        // Not destructuring assignment — fall through to normal expression parsing
    }

    // Parse LHS with lhs_mode enabled — member_expr saves (obj, key) without GETPROP
    self.lhs_mode = true;
    self.last_was_member = false;
    ushort left = self.conditional_expr()!;
    self.lhs_mode = false;

    TokenType tt2 = self.peek_type();

    // If LHS was a member expression but next token is NOT an assignment,
    // free the saved obj/key registers (GETPROP was already emitted)
    if (self.last_was_member && tt2 != TokenType.ASSIGN
        && tt2 != TokenType.PLUS_ASSIGN && tt2 != TokenType.MINUS_ASSIGN
        && tt2 != TokenType.STAR_ASSIGN && tt2 != TokenType.SLASH_ASSIGN
        && tt2 != TokenType.PERCENT_ASSIGN && tt2 != TokenType.STARSTAR_ASSIGN
        && tt2 != TokenType.SHL_ASSIGN && tt2 != TokenType.SHR_ASSIGN
        && tt2 != TokenType.USHR_ASSIGN && tt2 != TokenType.BIT_AND_ASSIGN
        && tt2 != TokenType.BIT_OR_ASSIGN && tt2 != TokenType.BIT_XOR_ASSIGN
        && tt2 != TokenType.LOG_AND_ASSIGN && tt2 != TokenType.LOG_OR_ASSIGN
        && tt2 != TokenType.NULLISH_ASSIGN) {
        self.free_reg(self.last_member_prop_reg);
        self.free_reg(self.last_member_obj_reg);
        self.last_was_member = false;
    }

    TokenType tt = tt2;

    // Check for assignment operators
    Opcode compound_op;
    bool is_compound = false;
    bool is_assign = false;
    bool is_logical_and_assign = false;
    bool is_logical_or_assign = false;
    bool is_nullish_assign = false;

    switch (tt) {
        case TokenType.ASSIGN:
            is_assign = true;
            break;
        case TokenType.PLUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.ADD;
            break;
        case TokenType.MINUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SUB;
            break;
        case TokenType.STAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MUL;
            break;
        case TokenType.SLASH_ASSIGN:
            is_compound = true;
            compound_op = Opcode.DIV;
            break;
        case TokenType.PERCENT_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MOD;
            break;
        case TokenType.STARSTAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.EXP;
            break;
        case TokenType.SHL_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHL;
            break;
        case TokenType.SHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHR;
            break;
        case TokenType.USHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.USHR;
            break;
        case TokenType.BIT_AND_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BAND;
            break;
        case TokenType.BIT_OR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BOR;
            break;
        case TokenType.BIT_XOR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BXOR;
            break;
        case TokenType.LOG_AND_ASSIGN:
            is_logical_and_assign = true;
            break;
        case TokenType.LOG_OR_ASSIGN:
            is_logical_or_assign = true;
            break;
        case TokenType.NULLISH_ASSIGN:
            is_nullish_assign = true;
            break;
        default:
            return left;
    }

    // Consume the assignment operator
    self.advance()!;

    // Save LHS info (will be overwritten by RHS evaluation)
    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;
    bool lhs_was_member = self.last_was_member;
    ushort lhs_member_obj = self.last_member_obj_reg;
    ushort lhs_member_prop = self.last_member_prop_reg;

    // Peek for a literal-1 RHS: `<var> += 1` → INC, `<var> -= 1` → DEC.
    // Saves a register + LDINT 1 instruction per occurrence (hot in counters).
    if (is_compound && !lhs_was_member) {
        if (self.peek_type() == TokenType.NUMBER) {
            Token num_tok2 = self.lexer.peek()!;
            double nv = num_tok2.num_value;
            if (nv == 1.0 && compound_op == Opcode.ADD) {
                self.advance()!;  // consume the literal
                if (lhs_was_getvar && self.code_count > 0
                    && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                    // Replace the GETVAR with INC_VAR: 1 instruction instead of 3
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    uint getvar_reg = self.code[self.code_count - 1].a;
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, getvar_reg, name_idx);
                } else {
                    self.emit_abc(Opcode.INC, (uint)left, 0, 0);
                    if (lhs_was_getvar) {
                        self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                    }
                }
                return left;
            }
            if (nv == 1.0 && compound_op == Opcode.SUB) {
                self.advance()!;
                if (lhs_was_getvar && self.code_count > 0
                    && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    uint getvar_reg = self.code[self.code_count - 1].a;
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, getvar_reg, name_idx);
                } else {
                    self.emit_abc(Opcode.DEC, (uint)left, 0, 0);
                    if (lhs_was_getvar) {
                        self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                    }
                }
                return left;
            }
        }
    }

    // Handle logical assignment operators with short-circuit semantics
    // x ||= expr  →  if (x) return x; x = expr; return expr;
    // x &&= expr  →  if (!x) return x; x = expr; return expr;
    // x ??= expr  →  if (x != null && x != undefined) return x; x = expr; return expr;
    if (is_logical_and_assign || is_logical_or_assign || is_nullish_assign) {
        // For member expressions, allocate a result register for the assigned value.
        // The short-circuit path returns the original LHS (left); the assign path returns RHS.
        ushort la_result = left;
        if (lhs_was_member) {
            la_result = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)left, 0);
        }

        if (is_logical_or_assign) {
            // x ||= expr: skip RHS if left is truthy
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)left);
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_logical_and_assign) {
            // x &&= expr: skip RHS if left is falsy
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)left);
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_nullish_assign) {
            // x ??= expr: skip RHS if left is NOT null/undefined
            ushort cmp_reg = self.alloc_reg();
            // Check null
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Check undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Not nullish — skip RHS
            self.free_reg(cmp_reg);
            uint skip_jump = self.emit_jump(Opcode.JUMP);
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);
            // Nullish — evaluate RHS and assign
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
    }

    // Compile right-hand side
    ushort right = self.assignment_expr()!;

    if (is_assign) {
        if (lhs_was_member) {
            // Member expression assignment: obj.prop = right
            self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
            self.free_reg(lhs_member_prop);
            self.free_reg(lhs_member_obj);
            self.free_reg(right);
            left = right;
        } else {
            // Simple assignment: left = right
            if (left != right) {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            }
            self.free_reg(right);
            if (lhs_was_getvar) {
                // PUTVAR clears the source register, so save the value
                // in a temp before writing back to the environment.
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                self.free_reg(left);
                left = tmp;
            }
        }
        return left;
    }

    if (is_compound) {
        // Compound assignment: left op= right => left = left op right.
        // For local variable registers, use the destination register in-place
        // when the op reads both operands before writing (ADD/SUB/MUL) and the
        // right operand doesn't alias left. Otherwise copy to a temp first to
        // avoid register corruption.
        ushort result_reg = left;
        bool can_inplace =
            (compound_op == Opcode.ADD || compound_op == Opcode.SUB || compound_op == Opcode.MUL)
            && left != right;
        if (!lhs_was_getvar && !lhs_was_member && !can_inplace) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            result_reg = tmp;
        }
        self.emit_abc(compound_op, (uint)result_reg, (uint)result_reg, (uint)right);
        self.free_reg(right);
        if (!lhs_was_getvar && !lhs_was_member && result_reg != left) {
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)result_reg, 0);
            self.free_reg(result_reg);
        }
        // If LHS was resolved via GETVAR, write back to environment.
        // PUTVAR clears the source register, so copy to a temp first
        // so the result survives the clobber.
        if (lhs_was_getvar) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
            self.free_reg(left);
            left = tmp;
        }
        return left;
    }

    return left;
}

/// Parse a conditional (ternary) expression: expr ? expr : expr
fn ushort? CompilerContext.conditional_expr(&self) {
    ushort result = self.binary_expr(PREC_NULLISH)!;

    if (self.match(TokenType.QUESTION)) {
        // Allocate result register
        ushort result_reg = self.alloc_reg();

        // Jump to else branch if condition is false
        uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)result);
        self.free_reg(result);

        // True branch
        ushort true_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)true_val, 0);
        self.free_reg(true_val);

        self.expect(TokenType.COLON)!;

        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // False branch
        ushort false_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)false_val, 0);
        self.free_reg(false_val);

        self.patch_jump(end_jump);

        return result_reg;
    }

    return result;
}

/// Parse binary expressions using a Pratt parser with precedence climbing.
fn ushort? CompilerContext.binary_expr(&self, int min_prec) {
    self.last_was_local_var = false;
    ushort left = self.unary_expr()!;
    bool left_is_local = self.last_was_local_var;

    for (;;) {
        self.last_was_local_var = false;
        TokenType tt = self.peek_type();
        int prec = get_binary_precedence(tt);

        if (prec < min_prec) {
            break;
        }

        // Handle short-circuit operators specially
        if (tt == TokenType.LOG_AND) {
            self.advance()!;
            // Short-circuit: if left is falsy, skip right and result is left
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)left);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        if (tt == TokenType.LOG_OR) {
            self.advance()!;
            // Short-circuit: if left is truthy, skip right and result is left
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)left);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        if (tt == TokenType.NULLISH) {
            self.advance()!;
            // Nullish coalescing: if left is not null/undefined, use left.
            // Reuse left as result register (no separate allocation).
            ushort cmp_reg = self.alloc_reg();
            // Check null
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Check undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);

            self.free_reg(cmp_reg);

            // Not nullish — skip right side
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch null and undefined jumps to here (right side)
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        // Regular binary operator
        self.advance()!;

        // Right-to-left associativity for exponentiation
        int next_prec = prec + 1;
        if (tt == TokenType.STARSTAR) {
            next_prec = prec;  // right-associative
        }

        ushort right = self.binary_expr(next_prec)!;
        bool right_is_local = self.last_was_local_var;

        // Determine opcode
        Opcode op = token_to_binary_opcode(tt);

        // If left is a live local variable register, we cannot use it as the
        // destination (it would clobber the variable). Copy it to a fresh temp.
        if (left_is_local) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            left = tmp;
            left_is_local = false;
        }

        self.emit_abc(op, (uint)left, (uint)left, (uint)right);
        self.free_reg(right);
        left_is_local = right_is_local;  // propagate for chained ops
    }

    return left;
}

/// Parse a unary expression.
fn ushort? CompilerContext.unary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.MINUS:
            self.advance()!;
            ushort operand = self.unary_expr()!;
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.UNM, (uint)result, (uint)operand, 0);
            self.free_reg(operand);
            return result;

        case TokenType.PLUS:
            self.advance()!;
            ushort op_plus = self.unary_expr()!;
            ushort res_plus = self.alloc_reg();
            self.emit_abc(Opcode.UNP, (uint)res_plus, (uint)op_plus, 0);
            self.free_reg(op_plus);
            return res_plus;

        case TokenType.LOG_NOT:
            self.advance()!;
            ushort op_not = self.unary_expr()!;
            ushort res_not = self.alloc_reg();
            self.emit_abc(Opcode.LNOT, (uint)res_not, (uint)op_not, 0);
            self.free_reg(op_not);
            return res_not;

        case TokenType.BIT_NOT:
            self.advance()!;
            ushort op_bnot = self.unary_expr()!;
            ushort res_bnot = self.alloc_reg();
            self.emit_abc(Opcode.BNOT, (uint)res_bnot, (uint)op_bnot, 0);
            self.free_reg(op_bnot);
            return res_bnot;

        case TokenType.TYPEOF:
            self.advance()!;
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // (does NOT throw ReferenceError).  For bare identifiers we emit a
            // dedicated TYPEOFIDENT opcode that handles the not-found case.
            // For dotted/computed/call expressions (X.y, X[y], X()), fall through
            // to normal expression parsing so the member chain is fully consumed.
            {
                Token? peeked = self.lexer.peek();
                if (try idTok = peeked) {
                    if (idTok.type == TokenType.IDENTIFIER &&
                        !str_eq(idTok.str_value, "true") &&
                        !str_eq(idTok.str_value, "false") &&
                        !str_eq(idTok.str_value, "null") &&
                        !str_eq(idTok.str_value, "undefined")) {
                        self.advance()!;  // consume the identifier
                        // Peek one more token to check for member/call access
                        Token? peeked2 = self.lexer.peek();
                        bool is_member = false;
                        if (try tok2 = peeked2) {
                            is_member = tok2.type == TokenType.DOT ||
                                        tok2.type == TokenType.LBRACKET ||
                                        tok2.type == TokenType.LPAREN;
                        }
                        if (is_member) {
                            // Not a bare identifier — push back and fall through
                            // to normal typeof expr (will parse the member expr)
                            self.pushback(idTok);
                        } else {
                            uint name_idx = self.add_string_constant(idTok.str_value);
                            ushort res_typeof = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.TYPEOFIDENT, (uint)res_typeof, name_idx));
                            return res_typeof;
                        }
                    }
                }
            }
            // Fallback: normal typeof expr
            ushort op_typeof = self.unary_expr()!;
            ushort res_typeof = self.alloc_reg();
            self.emit_abc(Opcode.TYPEOF, (uint)res_typeof, (uint)op_typeof, 0);
            self.free_reg(op_typeof);
            return res_typeof;

        case TokenType.VOID:
            self.advance()!;
            ushort op_void = self.unary_expr()!;
            ushort res_void = self.alloc_reg();
            self.emit_abc(Opcode.VOID, (uint)res_void, (uint)op_void, 0);
            self.free_reg(op_void);
            return res_void;

        case TokenType.DELETE:
            self.advance()!;
            // Parse operand with del_mode to track member expression (obj.prop).
            // member_expr emits GETPROP as usual; we patch it to DELPROP below.
            // We use del_mode (not lhs_mode) because expression() inside [bracket]
            // calls assignment_expr which resets lhs_mode.
            self.del_mode = true;
            self.last_was_member = false;
            ushort op_del = self.unary_expr()!;
            self.del_mode = false;

            if (self.last_was_member) {
                // Patch the last emitted instruction from GETPROP to DELPROP.
                // Both have identical register layout: A = result, B = obj, C = key.
                uint last_idx = self.code_count;
                if (last_idx > 0) {
                    last_idx--;
                    Instruction last_insn = self.code[last_idx];
                    if (last_insn.op == Opcode.GETPROP) {
                        self.code[last_idx] = bytecode::make_abc(
                            Opcode.DELPROP,
                            last_insn.a, last_insn.b, last_insn.c);
                    }
                }
                // Free saved registers (prop before obj).
                self.free_reg(self.last_member_prop_reg);
                self.free_reg(self.last_member_obj_reg);
                self.last_was_member = false;
                // op_del is the A register of the patched DELPROP (boolean).
                return op_del;
            } else {
                // Delete of a non-reference (variable, literal, etc.).
                // ES5 §11.4.1 / ES6 §12.5.3: SyntaxError in strict mode.
                // Strict-only engine: always reject (early SyntaxError).
                return COMPILE_ERROR~;
            }

        case TokenType.INC:
            // Prefix ++
            self.advance()!;
            self.lhs_mode = true;
            ushort op_inc = self.postfix_expr()!;
            self.lhs_mode = false;
            // postfix_expr leaves self.last_was_getvar / self.last_was_member
            // (and the member obj/prop registers) set so we can inspect the
            // LHS shape here. Member takes priority over getvar because for
            // `obj.prop` both flags can be true: member_expr keeps the
            // obj/prop registers alive, and the trailing GETPROP for the
            // value leaves the last emitted instruction as GETPROP (not
            // GETVAR), so the GETVAR branch would also miss its target.
            bool inc_was_getvar = self.last_was_getvar;
            uint inc_getvar_name_idx = self.last_getvar_name_idx;
            bool inc_was_member = self.last_was_member;
            ushort inc_member_obj = self.last_member_obj_reg;
            ushort inc_member_prop = self.last_member_prop_reg;

            if (inc_was_member) {
                // INC + PUTPROP for member access (e.g. ++obj.prop).
                self.emit_abc(Opcode.INC, (uint)op_inc, 0, 0);
                self.emit_abc(Opcode.PUTPROP, (uint)inc_member_obj, (uint)inc_member_prop, (uint)op_inc);
                self.free_reg(inc_member_prop);
                self.free_reg(inc_member_obj);
            } else if (inc_was_getvar && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                // Replace GETVAR with INC_VAR: 1 dispatch instead of 3
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, getvar_reg, name_idx);
            } else {
                self.emit_abc(Opcode.INC, (uint)op_inc, 0, 0);
                if (inc_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)op_inc, inc_getvar_name_idx);
                }
            }
            self.last_was_getvar = false;
            self.last_was_member = false;
            return op_inc;

        case TokenType.DEC:
            // Prefix --
            self.advance()!;
            self.lhs_mode = true;
            ushort op_dec = self.postfix_expr()!;
            self.lhs_mode = false;
            // See INC case above for why member takes priority over getvar.
            bool dec_was_getvar = self.last_was_getvar;
            uint dec_getvar_name_idx = self.last_getvar_name_idx;
            bool dec_was_member = self.last_was_member;
            ushort dec_member_obj = self.last_member_obj_reg;
            ushort dec_member_prop = self.last_member_prop_reg;

            if (dec_was_member) {
                // DEC + PUTPROP for member access (e.g. --obj.prop).
                self.emit_abc(Opcode.DEC, (uint)op_dec, 0, 0);
                self.emit_abc(Opcode.PUTPROP, (uint)dec_member_obj, (uint)dec_member_prop, (uint)op_dec);
                self.free_reg(dec_member_prop);
                self.free_reg(dec_member_obj);
            } else if (dec_was_getvar && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, getvar_reg, name_idx);
            } else {
                self.emit_abc(Opcode.DEC, (uint)op_dec, 0, 0);
                if (dec_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)op_dec, dec_getvar_name_idx);
                }
            }
            self.last_was_getvar = false;
            self.last_was_member = false;
            return op_dec;

        case TokenType.NEW:
            return self.new_expr()!;

        default:
            return self.postfix_expr()!;
    }
}

/// Parse postfix expressions (++, --).
///
/// NOTE: We deliberately do NOT set `self.lhs_mode = true` here. Doing so
/// would change how `member_expr` behaves for ALL nested member expressions
/// inside `call_expr` — including callees of method calls like `foo.bar()` —
/// keeping their obj/prop registers alive and marking them as LHS members,
/// which breaks unrelated code. Instead we let `member_expr` always track
/// `last_was_member` (and save obj/prop registers), let `call_expr` clear
/// `last_was_member` after emitting a call, and then inspect the flag here
/// to decide whether to emit INC/DEC + PUTPROP for a member LHS.
///
/// For a member LHS (e.g. `obj.prop++`), the GETPROP emitted by member_expr
/// is still in the bytecode stream. We NOP it (its result is now in `saved`
/// and we will overwrite `operand` with INC) and use the saved obj/prop
/// registers to emit a follow-up PUTPROP that writes the new value back.
fn ushort? CompilerContext.postfix_expr(&self) {
    ushort operand = self.call_expr()!;

    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;

    // Note: self.last_was_getvar / self.last_was_member remain set so that
    // outer callers (e.g. unary_expr INC/DEC) can read the LHS info. The
    // INC/DEC handlers below clear these after consuming the LHS info.

    TokenType tt = self.peek_type();
    if (tt == TokenType.INC) {
        self.advance()!;
        // Save original value and convert to ToNumber (ES5 §11.3.1)
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);
        self.emit_abc(Opcode.UNP, (uint)saved, (uint)saved, 0);

        // If the LHS was a member expression (e.g. obj.prop), emit INC +
        // PUTPROP to write the new value back. The GETPROP emitted by
        // member_expr already loaded the value into `operand`; we keep it
        // (do NOT NOP it) so the register has the correct value at runtime.
        // The obj/prop register indices are saved in last_member_obj_reg /
        // last_member_prop_reg by member_expr (and kept alive by the
        // is_postfix check there).
        bool handled = false;
        if (self.last_was_member) {
            ushort obj_reg = self.last_member_obj_reg;
            ushort prop_reg = self.last_member_prop_reg;
            // INC the operand (the property value already in the register).
            self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
            // Write back to the property.
            self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)prop_reg, (uint)operand);
            self.free_reg(prop_reg);
            self.free_reg(obj_reg);
            handled = true;
        }
        if (!handled) {
            if (lhs_was_getvar) {
                self.emit_a_bc(Opcode.INC_VAR, 0, lhs_getvar_name_idx);
                self.emit_abc(Opcode.NOP, 0, 0, 0);
            } else {
                self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
            }
        }
        self.last_was_getvar = false;
        self.last_was_member = false;
        return saved;
    }

    if (tt == TokenType.DEC) {
        self.advance()!;
        // Save original value and convert to ToNumber (ES5 §11.3.1)
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);
        self.emit_abc(Opcode.UNP, (uint)saved, (uint)saved, 0);

        bool handled = false;
        if (self.last_was_member) {
            ushort obj_reg = self.last_member_obj_reg;
            ushort prop_reg = self.last_member_prop_reg;
            self.emit_abc(Opcode.DEC, (uint)operand, 0, 0);
            self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)prop_reg, (uint)operand);
            self.free_reg(prop_reg);
            self.free_reg(obj_reg);
            handled = true;
        }
        if (!handled) {
            if (lhs_was_getvar) {
                self.emit_a_bc(Opcode.DEC_VAR, 0, lhs_getvar_name_idx);
                self.emit_abc(Opcode.NOP, 0, 0, 0);
            } else {
                self.emit_abc(Opcode.DEC, (uint)operand, 0, 0);
            }
        }
        self.last_was_getvar = false;
        self.last_was_member = false;
        return saved;
    }

    // No postfix INC/DEC: leave self.last_was_member etc. set so outer
    // callers (e.g. unary_expr INC/DEC) can inspect the LHS shape.
    return operand;
}

/// Parse call expressions: f(), f(a,b), obj.method(), obj[expr](), tag`...`.
fn ushort? CompilerContext.call_expr(&self) {
    ushort callee = self.member_expr()!;

    // If member_expr saved a property object but next token is not a call,
    // free the object register now.
    if (self.call_prop_obj_reg != MAX_REGISTERS
        && !self.check(TokenType.LPAREN)
        && !self.is_next_template()) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    for (;;) {
        if (self.check(TokenType.LPAREN)) {
            callee = self.emit_call(callee)!;
            // The result of a call is not a member expression and not a
            // direct variable reference. member_expr may have set
            // last_was_member for the callee (e.g. obj.prop) and
            // primary_expr may have set last_was_getvar for the base of
            // the member chain (e.g. obj in obj.prop). Both flags are
            // stale after a call: the call result is in a new register
            // and is not a referenceable member or variable. Clear both
            // flags so postfix_expr (and unary_expr for prefix ++/--)
            // correctly treat the result as a non-member non-variable.
            // If the call is followed by a member access (e.g. foo().bar),
            // the DOT/LBRACKET branch below will set the flags again.
            self.last_was_member = false;
            self.last_was_getvar = false;
            // Free the property object used as 'this' (if any)
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
        } else if (self.is_next_template()) {
            callee = self.emit_tagged_template(callee)!;
            // See comment in the LPAREN branch above.
            self.last_was_member = false;
            self.last_was_getvar = false;
            // Free the property object used as 'this' (if any)
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
        } else if (self.match(TokenType.DOT)) {
            // Property access: callee.name
            char[] prop_str = self.read_property_name()!;
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
            self.free_reg(prop_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN) || self.is_next_template()) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed property access: callee[expr]
            ushort idx_reg = self.expression()!;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)idx_reg);
            self.free_reg(idx_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN)) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.OPT_CHAIN)) {
            // Optional chaining: callee?.prop or callee?.()
            // Simplified: treat as regular property access for now
            if (self.check(TokenType.LPAREN)) {
                callee = self.emit_call(callee)!;
                // See comment in the LPAREN branch above.
                self.last_was_member = false;
                self.last_was_getvar = false;
            } else {
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);

                ushort prop_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
                self.free_reg(prop_reg);
                self.free_reg(callee);
                callee = result;
            }
        } else {
            break;
        }
    }

    return callee;
}

/// Emit a function call for the callee in the given register.
///
/// Calling convention (matching original Duktape):
///   callee_reg + 0  = callee (function object)
///   callee_reg + 1  = arg 1
///   callee_reg + 2  = arg 2
///   ...
///   callee_reg + N  = arg N
///
/// The result is placed in a separate result register (A field).
/// The VM reads args from callee_reg + 1, so we must guarantee that layout.
fn ushort? CompilerContext.emit_call(&self, ushort callee_reg) {
    self.expect(TokenType.LPAREN)!;

    // Detect direct eval: callee was the identifier `eval` (set by primary_expr)
    // and this is not a property call (obj.eval()).
    if (self.callee_is_eval && self.call_prop_obj_reg == MAX_REGISTERS) {
        self.has_direct_eval = true;
    }
    // Consume the flag so it doesn't leak to subsequent calls.
    self.callee_is_eval = false;

    // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
    ushort first_arg = callee_reg + 2;

    // If the argument region overlaps with live registers (from an outer call),
    // move the callee to a free area first.  Otherwise an inner call's arg setup
    // would clobber live values (e.g. print(add(1,2)) clobbers print in r1).
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        // Account for the callee's new position so args don't overlap
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }
    // Place undefined 'this' slot (or the property object for method calls)
    // DEBUG: check call_prop_obj_reg
    if (self.call_prop_obj_reg != MAX_REGISTERS) {
        // DEBUG: print the register number via stderr
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)self.call_prop_obj_reg, 0);
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Compile arguments into consecutive registers starting at first_arg
    ushort arg_count = 0;
    bool has_spread = false;
    ushort spread_count_reg = MAX_REGISTERS;
    ushort total_count_reg = MAX_REGISTERS;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for spread argument
            if (self.match(TokenType.ELLIPSIS)) {
                // Ensure the destination area doesn't overlap with the
                // register that will hold the spread expression result.
                ushort dest_start = first_arg + arg_count;
                if (self.next_reg <= dest_start + 1) {
                    self.next_reg = dest_start + 2;
                }

                ushort spread_reg = self.assignment_expr()!;

                // Move spread source away from the dest area if it overlaps
                if (spread_reg >= dest_start && spread_reg <= dest_start + 10) {
                    ushort safe_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDREG, (uint)safe_reg, (uint)spread_reg, 0);
                    self.free_reg(spread_reg);
                    spread_reg = safe_reg;
                }

                if (!has_spread) {
                    has_spread = true;
                    // Allocate count registers
                    spread_count_reg = self.alloc_reg();
                    total_count_reg = self.alloc_reg();
                    // Initialize total count with non-spread args so far
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count));
                }

                // SPREAD_ARG: A=dest_start_reg, B=count_out_reg, C=source_reg
                self.emit_abc(Opcode.SPREAD_ARG, (uint)dest_start, (uint)spread_count_reg, (uint)spread_reg);
                self.free_reg(spread_reg);

                // total_count += spread_count
                self.emit_abc(Opcode.ADD, (uint)total_count_reg, (uint)total_count_reg, (uint)spread_count_reg);

                // Adjust next_reg past the worst-case spread area
                // (conservatively reserve space; actual count is only known at runtime)
                if (self.next_reg <= dest_start + 1) {
                    self.next_reg = dest_start + 2;
                }
            } else {
                ushort arg_reg = self.assignment_expr()!;
                // Ensure the argument is in the expected consecutive register
                ushort expected = first_arg + arg_count;
                if (arg_reg != expected) {
                    self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                    self.free_reg(arg_reg);
                    if (self.next_reg <= expected) {
                        self.next_reg = expected + 1;
                    }
                }
                arg_count++;
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (self.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    self.expect(TokenType.RPAREN)!;

    // Emit CALL or CALL_S, reusing callee_reg as result (callee+this consumed by call)
    if (has_spread) {
        // CALL_S: A=result, B=callee_reg, C=nargs_reg — reuse callee_reg for result
        self.emit_abc(Opcode.CALL_S, (uint)callee_reg, (uint)callee_reg, (uint)total_count_reg);
    } else {
        self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, (uint)arg_count);
    }

    // Free everything from callee_reg (callee, this, args, spread temps)
    self.free_regs_to(callee_reg);
    // Result lives at callee_reg
    self.next_reg = callee_reg + 1;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    return callee_reg;
}

/// Emit a tagged template call: tag`...` or tag`text ${expr} text`.
///
/// The callee register is already set by member_expr.
/// Template parts become the first argument (a template object array),
/// and embedded expressions become subsequent arguments.
///
/// Calling convention:
///   callee_reg + 0  = callee (tag function)
///   callee_reg + 1  = this (undefined or object for member expressions)
///   callee_reg + 2  = arg 1 (template object array)
///   callee_reg + 3  = arg 2 (expr 1)
///   ...
fn ushort? CompilerContext.emit_tagged_template(&self, ushort callee_reg) {
    // Save the member expression object (if any) for 'this' binding
    ushort obj_reg = MAX_REGISTERS;
    if (self.call_prop_obj_reg != MAX_REGISTERS) {
        obj_reg = self.call_prop_obj_reg;
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    // Maximum number of template parts (head + middle*s + tail)
    const uint MAX_TEMPLATE_PARTS = 32;

    // Collect string parts and expression registers
    uint[MAX_TEMPLATE_PARTS] str_indices;
    ushort[MAX_TEMPLATE_PARTS] expr_regs;
    uint part_count = 0;
    uint expr_count = 0;

    TokenType tt = self.peek_type();

    // No-substitution template: tag`hello` (lexer returns STRING with is_template)
    if (tt == TokenType.STRING) {
        Token str_tok = self.advance()!;
        if (!str_tok.is_template) {
            return COMPILE_ERROR~;
        }
        str_indices[0] = self.add_string_constant(str_tok.str_value);
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE) {
        // Legacy TEMPLATE token (should not normally appear, but handle gracefully)
        Token tmpl_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(tmpl_tok.str_value);
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE_HEAD) {
        // Template with substitutions: `text${expr}text${expr}text`
        Token head_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(head_tok.str_value);
        part_count = 1;

        // Compile first expression
        expr_regs[0] = self.expression()!;
        expr_count = 1;

        // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
        for (;;) {
            TokenType next_tt = self.peek_type();
            if (next_tt == TokenType.TEMPLATE_MIDDLE) {
                Token mid_tok = self.advance()!;
                str_indices[part_count] = self.add_string_constant(mid_tok.str_value);
                part_count++;

                expr_regs[expr_count] = self.expression()!;
                expr_count++;
            } else if (next_tt == TokenType.TEMPLATE_TAIL) {
                Token tail_tok = self.advance()!;
                str_indices[part_count] = self.add_string_constant(tail_tok.str_value);
                part_count++;
                break;
            } else {
                return COMPILE_ERROR~;
            }
        }
    } else {
        return COMPILE_ERROR~;
    }

    // === Build the template object array ===
    // Create empty array
    ushort tmpl_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)tmpl_arr_reg, 0, 0);

    // Fill with string parts
    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_indices[i]));
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)tmpl_arr_reg, part_count));

    // Create raw array (copy of template array for now — raw === cooked)
    ushort raw_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)raw_arr_reg, 0, 0);

    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_indices[i]));
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)raw_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)raw_arr_reg, part_count));

    // Set .raw property on template array
    {
        uint raw_key_idx = self.add_string_constant("raw");
        ushort raw_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)raw_key_reg, raw_key_idx));
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)raw_key_reg, (uint)raw_arr_reg);
        self.free_reg(raw_key_reg);
        self.free_reg(raw_arr_reg);
    }

    // === Set up the call ===
    // Ensure callee is positioned so args don't overlap with live registers
    ushort first_arg = callee_reg + 2;
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }

    // Place 'this' slot
    if (obj_reg != MAX_REGISTERS) {
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)obj_reg, 0);
        self.free_reg(obj_reg);
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Place template array as first argument (callee_reg + 2)
    self.emit_abc(Opcode.LDREG, (uint)first_arg, (uint)tmpl_arr_reg, 0);
    self.free_reg(tmpl_arr_reg);

    // Place expression arguments in consecutive registers after template array
    for (uint i = 0; i < expr_count; i++) {
        ushort expected = first_arg + 1 + (ushort)i;
        if (expr_regs[i] != expected) {
            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)expr_regs[i], 0);
            self.free_reg(expr_regs[i]);
        }
    }

    // Update next_reg past all arguments
    ushort total_args = 1 + (ushort)expr_count;  // template array + expressions
    self.next_reg = first_arg + total_args;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    // Emit CALL: A=result, B=callee, C=arg count
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, (uint)total_args);

    return result_reg;
}

/// Parse new expression: new Constructor(args).
fn ushort? CompilerContext.new_expr(&self) {
    self.expect(TokenType.NEW)!;

    // Check for new.target meta-property
    if (self.match(TokenType.DOT)) {
        Token? target_tok_opt = self.lexer.next_token();
        if (catch err = target_tok_opt) return COMPILE_ERROR~;
        Token target_tok = target_tok_opt;
        char[] target_name = target_tok.str_value;
        if (target_name.len == 0) {
            target_name = lexer::keyword_to_string(target_tok.type);
        }
        if (target_name.len == 6
            && target_name[0] == 't'
            && target_name[1] == 'a'
            && target_name[2] == 'r'
            && target_name[3] == 'g'
            && target_name[4] == 'e'
            && target_name[5] == 't') {
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.NEWTARGET, (uint)result_reg, 0, 0);
            return result_reg;
        }
        // Not 'target' — error
        return COMPILE_ERROR~;
    }

    // Parse the constructor (could be member access)
    ushort ctor_reg = self.member_expr()!;

    // Args start right after constructor (same convention as emit_call)
    ushort first_arg = ctor_reg + 2;
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }
    ushort arg_count = 0;

    if (self.match(TokenType.LPAREN)) {
        if (!self.check(TokenType.RPAREN)) {
            for (;;) {
                ushort arg_reg = self.assignment_expr()!;
                ushort expected = first_arg + arg_count;
                if (arg_reg != expected) {
                    self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                    self.free_reg(arg_reg);
                }
                arg_count++;

                if (!self.match(TokenType.COMMA)) {
                    break;
                }
                // Trailing comma: ',)' is valid per ES2017
                if (self.check(TokenType.RPAREN)) {
                    break;
                }
            }
        }
        self.expect(TokenType.RPAREN)!;
    }

    // Emit NEW_OBJ: reuse ctor_reg as result (ctor consumed by new)
    self.emit_abc(Opcode.NEW_OBJ, (uint)ctor_reg, (uint)ctor_reg, (uint)arg_count);

    self.free_regs_to(ctor_reg);
    self.next_reg = ctor_reg + 1;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    // Handle trailing member access and calls: new X().prop, new X()[idx], new X().method()
    for (;;) {
        if (self.match(TokenType.DOT)) {
            Token? prop_name_opt = self.lexer.next_token();
            if (catch err = prop_name_opt) return COMPILE_ERROR~;
            Token prop_name = prop_name_opt;
            char[] prop_str = prop_name.str_value;
            if (prop_str.len == 0) {
                prop_str = lexer::keyword_to_string(prop_name.type);
            }
            if (prop_name.type != TokenType.IDENTIFIER && prop_str.len == 0) {
                return COMPILE_ERROR~;
            }
            uint prop_const = self.add_string_constant(prop_str);
            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)ctor_reg, (uint)prop_reg);
            self.free_reg(prop_reg);
            // Check if this is a method call: new X().method(args)
            if (self.check(TokenType.LPAREN)) {
                // Keep ctor_reg alive as 'this' for the method call
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
                ctor_reg = self.emit_call(ctor_reg)!;
            } else {
                self.free_reg(ctor_reg);
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
            }
        } else if (self.match(TokenType.LBRACKET)) {
            ushort saved_prop_obj = self.call_prop_obj_reg;
            ushort idx_reg = self.expression()!;
            self.call_prop_obj_reg = saved_prop_obj;
            self.expect(TokenType.RBRACKET)!;
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)ctor_reg, (uint)idx_reg);
            self.free_reg(idx_reg);
            self.free_reg(ctor_reg);
            ctor_reg = result;
            self.next_reg = ctor_reg + 1;
        } else {
            break;
        }
    }

    return ctor_reg;
}

/// Parse member expression: property accesses and computed accesses.
fn ushort? CompilerContext.member_expr(&self) {
    self.callee_is_eval = false;  // Reset before each callee resolution
    // Reset last_was_member: if the loop runs, it will be set to true.
    // This ensures that a non-member result (simple variable, literal) does
    // not inherit a stale true value from a prior expression.
    self.last_was_member = false;
    ushort obj = self.primary_expr()!;

    for (;;) {
        if (self.match(TokenType.DOT)) {
            // Member access (obj.prop) — not a direct identifier reference,
            // so clear the direct eval flag.
            self.callee_is_eval = false;
            // Get next token — after '.' it can be an identifier OR any keyword
            // (ES5 §11.2.1: property name must be an IdentifierName)
            Token? prop_name_opt = self.lexer.next_token();
            if (catch err = prop_name_opt) return COMPILE_ERROR~;
            Token prop_name = prop_name_opt;
            char[] prop_str = prop_name.str_value;
            // If it's a keyword, str_value was set; if not, use keyword_to_string
            if (prop_str.len == 0) {
                prop_str = lexer::keyword_to_string(prop_name.type);
            }
            if (prop_name.type != TokenType.IDENTIFIER && prop_str.len == 0) {
                return COMPILE_ERROR~;
            }
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            // Always emit GETPROP
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)prop_reg);

            // Always track if the result is a member expression. The saved
            // obj/prop registers are used by postfix_expr (and by unary_expr
            // for prefix ++/--) to emit PUTPROP after INC/DEC. The values in
            // those registers are preserved even in non-lhs/del mode because
            // the result register sits on top of the stack and free_reg is a
            // no-op for registers below the top.
            self.last_was_member = true;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = prop_reg;

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/prop alive for possible PUTPROP/DELPROP
                // Also set up for potential method call 'this'
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free obj/prop immediately, UNLESS the next token is
                // a postfix INC/DEC — in that case postfix_expr needs obj/prop alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free them.
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(prop_reg);
                }
                // If next token is LPAREN or a template, this is a method call.
                // Track the object for 'this' setup in emit_call / emit_tagged_template.
                if (next_tt == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else if (!is_postfix) {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed member access — not a direct identifier reference.
            self.callee_is_eval = false;
            // Save lhs_mode: the inner expression() calls assignment_expr()
            // which resets lhs_mode to false, clobbering the outer mode.
            bool saved_lhs = self.lhs_mode;
            ushort idx_reg = self.expression()!;
            self.lhs_mode = saved_lhs;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)idx_reg);

            // See DOT branch above for why we always track the member.
            self.last_was_member = true;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = idx_reg;

            if (self.del_mode || self.lhs_mode) {
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free obj/idx_reg immediately, UNLESS the next token is
                // a postfix INC/DEC — in that case postfix_expr needs them alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free them.
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(idx_reg);
                }
                if (next_tt == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else if (!is_postfix) {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else {
            break;
        }
    }

    return obj;
}

/// Parse primary expressions: literals, identifiers, grouping, etc.
fn ushort? CompilerContext.primary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.NUMBER:
            self.last_was_getvar = false;
            Token num_tok = self.advance()!;

            // Legacy octal integer literal (0 followed by octal digit 0-7)
            // is a SyntaxError (strict mode per ES5 §7.8.3 + B.1.1).
            char[] nsrc = num_tok.str_value;
            if (nsrc.len >= 2 && nsrc[0] == '0' && nsrc[1] >= '0' && nsrc[1] <= '7') {
                return COMPILE_ERROR~;
            }

            ushort num_reg = self.alloc_reg();

            // Check if it fits in a signed 16-bit immediate
            double val = num_tok.num_value;
            int int_val = (int)val;
            if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)num_reg, int_val));
            } else {
                uint const_idx = self.add_number_constant(val);
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)num_reg, const_idx));
            }
            return num_reg;

        case TokenType.STRING:
            Token str_tok = self.advance()!;

            // Legacy octal escape sequences in strings are SyntaxErrors
            // per ES5 §7.8.4 + Annex B.1.2.
            if (str_tok.has_octal_escape) {
                return COMPILE_ERROR~;
            }

            uint str_idx = self.add_string_constant(str_tok.str_value);
            ushort str_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_idx));
            return str_reg;

        case TokenType.IDENTIFIER:
            // Check for arrow function: IDENTIFIER ARROW => single param
            {
                // Detect `async function ...` expression: consume the async
                // identifier and delegate to function_expr with is_async set.
                if (self.peek_type() == TokenType.IDENTIFIER &&
                    self.match_async_function()) {
                    self.is_async = true;
                    ushort r = self.function_expr()!;
                    self.is_async = false;
                    return r;
                }
                Token id_tok = self.advance()!;

                // Check for literal keywords tokenized as identifiers
                if (str_eq(id_tok.str_value, "true")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDTRUE, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "false")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDFALSE, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "null")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDNULL, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "undefined")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
                    return reg;
                }

                // Arrow function: IDENTIFIER => ...
                if (self.check(TokenType.ARROW)) {
                    char[][1] params_arr;
                    params_arr[0] = id_tok.str_value;
                    return self.parse_arrow_function(&params_arr[0], 1, false)!;
                }

                // When the identifier is 'eval', track it for direct eval detection.
                // emit_call checks callee_is_eval to set has_direct_eval.
                // This must be set BEFORE the early return for local variables.
                self.callee_is_eval = str_eq(id_tok.str_value, "eval");

                // Try to resolve as a local variable first (skip at global scope — use environment)
                if (!self.is_global) {
                    if (try var_reg = self.resolve_var(id_tok.str_value)) {
                        self.last_was_getvar = false;
                        self.last_was_local_var = true;
                        self.last_local_var_reg = var_reg;
                        return var_reg;
                    }
                }

                // When 'arguments' is referenced inside a non-arrow function body,
                // set the uses_arguments flag so the VM creates the arguments object.
                if (str_eq(id_tok.str_value, "arguments") && !self.is_global) {
                    self.uses_arguments = true;
                }

                // Not found locally: emit GETVAR to look up by name at runtime
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                return id_reg;
            }

        case TokenType.THIS:
            self.advance()!;
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)this_reg, 0, 0);
            return this_reg;

        case TokenType.LPAREN: {
            // Try arrow function with parens: (params) => ...
            // Strategy: save lexer state, speculatively scan params, and check for =>.
            // If it's not an arrow, restore the lexer and parse as grouping expression.
            Token lparen = self.advance()!;

            // Save lexer state before speculative scan
            uint saved_pos    = self.lexer.pos;
            uint saved_line   = self.lexer.line;
            uint saved_col    = self.lexer.col;
            Token saved_cur   = self.lexer.current;
            Token saved_look  = self.lexer.lookahead;
            bool  saved_haslk = self.lexer.has_lookahead;
            Token saved_push  = self.lexer.pushed_back;
            bool  saved_haspb = self.lexer.has_pushed_back;
            bool  saved_slt   = self.lexer.seen_line_term;

            // Check for empty parens: () => ...
            if (self.check(TokenType.RPAREN)) {
                self.advance()!;  // consume ')'
                if (self.check(TokenType.ARROW)) {
                    // No-param arrow: () => ...
                    // Restore lexer to right after '(' — parse_arrow_function_reparse
                    // will re-parse from source.
                    self.lexer.pos             = saved_pos;
                    self.lexer.line            = saved_line;
                    self.lexer.col             = saved_col;
                    self.lexer.current         = saved_cur;
                    self.lexer.lookahead       = saved_look;
                    self.lexer.has_lookahead   = saved_haslk;
                    self.lexer.pushed_back     = saved_push;
                    self.lexer.has_pushed_back = saved_haspb;
                    self.lexer.seen_line_term  = saved_slt;
                    return self.parse_arrow_function_reparse()!;
                }
                // Not an arrow: restore lexer and parse as grouping expression
                self.lexer.pos             = saved_pos;
                self.lexer.line            = saved_line;
                self.lexer.col             = saved_col;
                self.lexer.current         = saved_cur;
                self.lexer.lookahead       = saved_look;
                self.lexer.has_lookahead   = saved_haslk;
                self.lexer.pushed_back     = saved_push;
                self.lexer.has_pushed_back = saved_haspb;
                self.lexer.seen_line_term  = saved_slt;
                ushort inner2 = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                return inner2;
            }
            // Check for arrow with params: (id) => or (id, id, ...) => ...
            else if (self.check(TokenType.IDENTIFIER) || self.check(TokenType.ELLIPSIS)) {
                char[][8] param_names;
                ushort pc = 0;
                bool has_rest = false;
                bool is_arrow = false;

                for (;;) {
                    // Check for rest parameter
                    if (self.check(TokenType.ELLIPSIS)) {
                        self.advance()!;  // consume '...'
                        Token t = self.advance()!;
                        if (t.type != TokenType.IDENTIFIER) {
                            break;  // not a valid rest param, can't be arrow
                        }
                        param_names[pc++] = t.str_value;
                        has_rest = true;

                        if (self.check(TokenType.RPAREN)) {
                            self.advance()!;  // consume ')'
                            if (self.check(TokenType.ARROW)) {
                                is_arrow = true;
                            }
                        }
                        break;
                    }

                    Token t = self.advance()!;
                    if (t.type != TokenType.IDENTIFIER) {
                        break;  // not a param name, can't be arrow
                    }
                    param_names[pc++] = t.str_value;

                    // Skip default value if present: = <expression>
                    if (self.check(TokenType.ASSIGN)) {
                        self.advance()!;  // consume '='
                        // Skip the default expression using the token scanner
                        self.skip_expression();
                    }

                    if (self.check(TokenType.RPAREN)) {
                        self.advance()!;  // consume ')'
                        if (self.check(TokenType.ARROW)) {
                            is_arrow = true;
                        }
                        break;
                    }
                    if (!self.check(TokenType.COMMA)) {
                        break;  // unexpected token, not arrow
                    }
                    self.advance()!;  // consume ','

                    // Trailing comma: ',)' is valid per ES2017
                    if (self.check(TokenType.RPAREN)) {
                        self.advance()!;  // consume ')'
                        if (self.check(TokenType.ARROW)) {
                            is_arrow = true;
                        }
                        break;
                    }
                }

                if (is_arrow) {
                    // Restore lexer to right after '(' — compile_arrow_inner
                    // will re-parse params from source (handling defaults).
                    self.lexer.pos             = saved_pos;
                    self.lexer.line            = saved_line;
                    self.lexer.col             = saved_col;
                    self.lexer.current         = saved_cur;
                    self.lexer.lookahead       = saved_look;
                    self.lexer.has_lookahead   = saved_haslk;
                    self.lexer.pushed_back     = saved_push;
                    self.lexer.has_pushed_back = saved_haspb;
                    self.lexer.seen_line_term  = saved_slt;
                    return self.parse_arrow_function_reparse()!;
                }

                // Not an arrow: restore lexer state and parse as grouping expression
                self.lexer.pos             = saved_pos;
                self.lexer.line            = saved_line;
                self.lexer.col             = saved_col;
                self.lexer.current         = saved_cur;
                self.lexer.lookahead       = saved_look;
                self.lexer.has_lookahead   = saved_haslk;
                self.lexer.pushed_back     = saved_push;
                self.lexer.has_pushed_back = saved_haspb;
                self.lexer.seen_line_term  = saved_slt;
                ushort inner2 = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                return inner2;
            }
            // Check for arrow with destructured params: ({a, b}) => or ([a, b]) =>
            else if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                // Scan through the destructuring pattern to check for ') =>'
                bool is_arrow = self.scan_destruct_param_to_arrow();

                if (is_arrow) {
                    // Restore lexer to right after '(' for re-parse
                    self.lexer.pos             = saved_pos;
                    self.lexer.line            = saved_line;
                    self.lexer.col             = saved_col;
                    self.lexer.current         = saved_cur;
                    self.lexer.lookahead       = saved_look;
                    self.lexer.has_lookahead   = saved_haslk;
                    self.lexer.pushed_back     = saved_push;
                    self.lexer.has_pushed_back = saved_haspb;
                    self.lexer.seen_line_term  = saved_slt;
                    return self.parse_arrow_function_reparse()!;
                }

                // Not an arrow: restore lexer and parse as grouping expression
                self.lexer.pos             = saved_pos;
                self.lexer.line            = saved_line;
                self.lexer.col             = saved_col;
                self.lexer.current         = saved_cur;
                self.lexer.lookahead       = saved_look;
                self.lexer.has_lookahead   = saved_haslk;
                self.lexer.pushed_back     = saved_push;
                self.lexer.has_pushed_back = saved_haspb;
                self.lexer.seen_line_term  = saved_slt;
                ushort inner2 = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                return inner2;
            } else {
                // Not arrow: parse as grouping expression
                ushort inner2 = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                return inner2;
            }
        }

        case TokenType.LBRACE:
            return self.object_literal()!;

        case TokenType.LBRACKET:
            return self.array_literal()!;

        case TokenType.FUNCTION:
            return self.function_expr()!;

        case TokenType.YIELD:
        {
            self.advance()!;  // consume 'yield'
            if (!self.is_generator) {
                return COMPILE_ERROR~;  // yield only valid in generators
            }
            // Check for yield* (delegating yield)
            bool is_delegate = false;
            if (self.match(TokenType.STAR)) {
                is_delegate = true;
            }

            ushort val_reg;
            if (is_delegate) {
                // yield* iterable — delegate to the inner iterable via the ES6 iterator protocol.
                // The YIELD_STAR opcode handles Getting the iterator, calling .next() in a
                // suspend/resume loop, and properly delegating .throw()/.return().
                ushort iterable_reg = self.assignment_expr()!;
                ushort result_reg = self.alloc_reg();
                self.emit_abc(Opcode.YIELD_STAR, (uint)result_reg, (uint)iterable_reg, 0);
                self.free_reg(iterable_reg);
                return result_reg;
            } else {
                // yield expression (optional)
                if (self.check(TokenType.SEMICOLON) || self.check(TokenType.RBRACE)
                    || self.check(TokenType.RPAREN) || self.check(TokenType.COMMA)
                    || self.check(TokenType.COLON) || self.check(TokenType.RBRACKET)
                    || self.is_at_end()) {
                    // yield without expression → yield undefined
                    ushort result = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)result, 0, 0);
                    self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
                    self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                    return result;
                }
                val_reg = self.assignment_expr()!;
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)result, (uint)val_reg, 0);
                self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
                self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                self.free_reg(val_reg);
                return result;
            }
        }

        // `await expr` — contextual keyword, only valid in async functions.
        // Emits AWAIT + LOAD_RESUME so the VM can suspend/resume at this point.
        case TokenType.AWAIT:
        {
            self.advance()!;  // consume 'await'
            if (!self.is_async) {
                return COMPILE_ERROR~;
            }
            ushort operand = self.unary_expr()!;
            // AWAIT suspends the async function; LOAD_RESUME loads the settled value
            self.emit_abc(Opcode.AWAIT, (uint)operand, 0, 0);
            self.emit_abc(Opcode.LOAD_RESUME, (uint)operand, 0, 0);
            return operand;
        }

        // `import(...)` — dynamic import expression (ES2020).
        // For now, emits LDUNDEF (deferred to a later phase).
        case TokenType.IMPORT:
        {
            self.advance()!;  // consume 'import'
            if (!self.match(TokenType.LPAREN)) {
                return COMPILE_ERROR~;  // import must be followed by '('
            }
            // Parse the specifier argument (we discard it for now)
            ushort spec_reg = self.assignment_expr()!;
            self.expect(TokenType.RPAREN)!;
            self.free_reg(spec_reg);
            // Dynamic import not yet implemented — return undefined
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.LDUNDEF, (uint)result, 0, 0);
            return result;
        }

        case TokenType.CLASS:
            return self.class_expression()!;

        case TokenType.SUPER:
        {
            self.advance()!;  // consume 'super'
            // super() — call superclass constructor
            if (self.match(TokenType.LPAREN)) {
                // Look up __super__ from the environment
                if (!self.has_super_binding) {
                    return COMPILE_ERROR~;  // super() only valid with extends
                }
                // super() only valid in constructors, not in methods/getters/setters
                if (!self.is_constructable) {
                    return COMPILE_ERROR~;
                }
                uint super_name_idx = self.add_string_constant("__super__");
                ushort super_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_reg, super_name_idx));

                // Parse arguments
                ushort first_arg = super_reg + 2;
                if (self.next_reg < first_arg) {
                    self.next_reg = first_arg;
                }
                ushort arg_count = 0;
                if (!self.check(TokenType.RPAREN)) {
                    for (;;) {
                        ushort arg_reg = self.assignment_expr()!;
                        ushort expected = first_arg + arg_count;
                        if (arg_reg != expected) {
                            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                            self.free_reg(arg_reg);
                            if (self.next_reg <= expected) {
                                self.next_reg = expected + 1;
                            }
                        }
                        arg_count++;
                        if (!self.match(TokenType.COMMA)) {
                            break;
                        }
                    }
                }
                self.expect(TokenType.RPAREN)!;

                // Place 'this' slot
                self.emit_abc(Opcode.LDTHIS, (uint)(super_reg + 1), 0, 0);

                // Emit SUPER_CALL, reusing super_reg as result
                self.emit_abc(Opcode.SUPER_CALL, (uint)super_reg, (uint)super_reg, (uint)arg_count);

                // Free arg regs and super_reg (callee+this no longer needed after SUPER_CALL)
                self.free_regs_to(super_reg);
                self.next_reg = super_reg + 1;
                if (self.next_reg > self.max_reg) {
                    self.max_reg = self.next_reg;
                }
                return super_reg;
            }

            // super.property — access property on superclass prototype
            // super[expr] — computed property access on superclass prototype
            if (self.check(TokenType.DOT) || self.check(TokenType.LBRACKET)) {
                if (!self.has_super_binding) {
                    return COMPILE_ERROR~;
                }
                uint super_name_idx = self.add_string_constant("__super__");
                ushort super_ctor_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_ctor_reg, super_name_idx));

                // Get super.prototype
                uint proto_name_idx = self.add_string_constant("prototype");
                ushort proto_key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
                ushort super_proto_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)super_proto_reg, (uint)super_ctor_reg, (uint)proto_key_reg);
                self.free_reg(proto_key_reg);
                self.free_reg(super_ctor_reg);

                // Now parse the property access
                ushort result;
                if (self.match(TokenType.DOT)) {
                    char[] prop_str = self.read_property_name()!;
                    uint prop_idx = self.add_string_constant(prop_str);
                    ushort prop_key_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_key_reg, prop_idx));
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP, (uint)result, (uint)super_proto_reg, (uint)prop_key_reg);
                    self.free_reg(prop_key_reg);

                    // Save for method call this-binding
                    // Don't use the super prototype as 'this' — use LDTHIS
                    // The this-binding for super.method() calls should be
                    // set by the caller (emit_call will use call_prop_obj_reg)
                    // But we don't have a good way to pass "this" from here.
                    // For now, just return the method; the caller handles this.
                    self.last_was_member = true;
                    self.last_member_obj_reg = super_proto_reg;
                    self.last_member_prop_reg = result;
                } else {
                    // super[expr]
                    self.advance()!;  // consume '['
                    ushort key_reg = self.expression()!;
                    self.expect(TokenType.RBRACKET)!;
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP, (uint)result, (uint)super_proto_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                }

                self.free_reg(super_proto_reg);
                return result;
            }

            return COMPILE_ERROR~;
        }

        case TokenType.TEMPLATE_HEAD:
        {
            // Template literal with substitutions: `text${expr}text${expr}text`
            Token head_tok = self.advance()!;
            uint head_idx = self.add_string_constant(head_tok.str_value);
            ushort result_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)result_reg, head_idx));

            // Parse the expression inside ${...}
            ushort expr_reg = self.expression()!;

            // Concatenate: result = result + expr  (ADD handles string coercion)
            {
                ushort concat_reg = self.alloc_reg();
                self.emit_abc(Opcode.ADD, (uint)concat_reg, (uint)result_reg, (uint)expr_reg);
                self.free_reg(expr_reg);
                self.free_reg(result_reg);
                result_reg = concat_reg;
            }

            // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
            for (;;) {
                TokenType next_tt = self.peek_type();
                if (next_tt == TokenType.TEMPLATE_MIDDLE) {
                    Token mid_tok = self.advance()!;
                    uint mid_idx = self.add_string_constant(mid_tok.str_value);
                    ushort mid_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)mid_reg, mid_idx));

                    // Concatenate the middle text
                    ushort concat_reg2 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg2, (uint)result_reg, (uint)mid_reg);
                    self.free_reg(result_reg);
                    self.free_reg(mid_reg);
                    result_reg = concat_reg2;

                    // Parse the next expression
                    ushort next_expr_reg = self.expression()!;

                    // Concatenate expression
                    ushort concat_reg3 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg3, (uint)result_reg, (uint)next_expr_reg);
                    self.free_reg(next_expr_reg);
                    self.free_reg(result_reg);
                    result_reg = concat_reg3;
                } else if (next_tt == TokenType.TEMPLATE_TAIL) {
                    Token tail_tok = self.advance()!;
                    uint tail_idx = self.add_string_constant(tail_tok.str_value);
                    ushort tail_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tail_reg, tail_idx));

                    // Concatenate the tail text
                    ushort concat_reg4 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg4, (uint)result_reg, (uint)tail_reg);
                    self.free_reg(result_reg);
                    self.free_reg(tail_reg);
                    result_reg = concat_reg4;

                    break;
                } else {
                    // Expected TEMPLATE_MIDDLE or TEMPLATE_TAIL
                    return COMPILE_ERROR~;
                }
            }

            return result_reg;
        }

        case TokenType.TEMPLATE:
            // Legacy fallback for old-style raw TEMPLATE token
            Token tmpl_tok = self.advance()!;
            uint tmpl_idx = self.add_string_constant(tmpl_tok.str_value);
            ushort tmpl_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tmpl_reg, tmpl_idx));
            return tmpl_reg;

        case TokenType.REGEXP: {
            Token re_tok = self.advance()!;
            uint re_idx = self.add_string_constant(re_tok.str_value);
            ushort re_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.NEWREGEXP, (uint)re_reg, re_idx));
            return re_reg;
        }

        default:
            // Check for literal keywords
            if (tt == TokenType.LET) {
                // 'let' used as identifier in non-strict mode
                Token let_tok = self.advance()!;
                if (try var_reg = self.resolve_var(let_tok.str_value)) {
                    return var_reg;
                }
                uint name_idx = self.add_string_constant(let_tok.str_value);
                ushort let_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)let_reg, name_idx));
                return let_reg;
            }
            return self.literal_keyword()!;
    }
}

/// Parse literal keyword values (true, false, null, undefined).
fn ushort? CompilerContext.literal_keyword(&self) {
    TokenType tt = self.peek_type();
    self.advance()!;

    ushort reg = self.alloc_reg();

    // Map certain keyword tokens to load instructions
    // The lexer produces these as keyword token types
    // We need to check the str_value for true/false/null/undefined
    // But those aren't separate token types in our lexer, so handle via
    // the token type directly:

    // Actually, looking at the lexer, true/false/null/undefined are
    // tokenized as IDENTIFIER tokens. Let's handle the case where
    // we reach here with an unexpected token.
    switch (tt) {
        default:
            // Emit LDUNDEF as a fallback for unrecognized primary expressions
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
    }

    return reg;
}

/// Parse object literal: { key: value, ... }
fn ushort? CompilerContext.object_literal(&self) {
    self.expect(TokenType.LBRACE)!;

    ushort obj_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWOBJ, (uint)obj_reg, 0, 0);

    // Track data property keys for duplicate detection in strict mode.
    // ES5 §11.1.5: duplicate PropertyName in PropertySetData is a
    // SyntaxError when contained in strict code.
    char[16][64] seen_key_buf;
    usz[16] seen_key_len;
    usz seen_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            if (self.check(TokenType.RBRACE)) {
                break;
            }

            // Parse property key
            ushort key_reg;

            TokenType key_tt = self.peek_type();
            if (key_tt == TokenType.IDENTIFIER || key_tt == TokenType.STRING) {
                Token key_tok = self.advance()!;

                // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
                // If key is "get" or "set" AND next token is a property key (not `:` or `(`)
                bool is_obj_getter = false;
                bool is_obj_setter = false;
                if (key_tt == TokenType.IDENTIFIER && !self.check(TokenType.COLON) && !self.check(TokenType.LPAREN)) {
                    if (key_tok.str_value.len == 3
                        && key_tok.str_value[0] == 'g'
                        && key_tok.str_value[1] == 'e'
                        && key_tok.str_value[2] == 't') {
                        is_obj_getter = true;
                    } else if (key_tok.str_value.len == 3
                        && key_tok.str_value[0] == 's'
                        && key_tok.str_value[1] == 'e'
                        && key_tok.str_value[2] == 't') {
                        is_obj_setter = true;
                    }
                }

                if (is_obj_getter || is_obj_setter) {
                    // Parse the actual property name
                    TokenType prop_tt = self.peek_type();
                    if (prop_tt == TokenType.LBRACKET) {
                        // Computed getter/setter key: `get [expr]() {}` / `set [expr](v) {}`
                        self.advance()!; // consume `[`
                        key_reg = self.assignment_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        Token prop_tok;
                        if (prop_tt == TokenType.IDENTIFIER || prop_tt == TokenType.STRING) {
                            prop_tok = self.advance()!;
                        } else if (prop_tt == TokenType.NUMBER) {
                            prop_tok = self.advance()!;
                        } else {
                            return COMPILE_ERROR~;
                        }

                        // Emit key constant
                        uint prop_key_idx;
                        if (prop_tt == TokenType.NUMBER) {
                            prop_key_idx = self.add_number_constant(prop_tok.num_value);
                        } else {
                            prop_key_idx = self.add_string_constant(prop_tok.str_value);
                        }
                        key_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, prop_key_idx));
                    }

                    // Compile the getter/setter function body
                    ushort accessor_reg = self.function_expr_body()!;

                    if (is_obj_getter) {
                        self.emit_abc(Opcode.INITGET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    } else {
                        self.emit_abc(Opcode.INITSET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    }
                    self.free_reg(accessor_reg);
                    self.free_reg(key_reg);

                    if (!self.match(TokenType.COMMA)) {
                        break;
                    }
                    continue;
                }

                // Regular property (not getter/setter)
                // Duplicate data property check (strict mode only — strict-only engine)
                for (usz i = 0; i < seen_count; i++) {
                    if (str_eq(seen_key_buf[i][:seen_key_len[i]], key_tok.str_value)) {
                        return COMPILE_ERROR~;
                    }
                }
                if (seen_count < 16 && key_tok.str_value.len < 64) {
                    for (usz j = 0; j < key_tok.str_value.len; j++) {
                        seen_key_buf[seen_count][j] = key_tok.str_value[j];
                    }
                    seen_key_len[seen_count] = key_tok.str_value.len;
                    seen_count++;
                }

                uint key_idx = self.add_string_constant(key_tok.str_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.NUMBER) {
                Token key_tok = self.advance()!;

                // Duplicate data property check (strict mode only — strict-only engine).
                // Convert number to canonical string via %.17g to match
                // vm_number_to_string runtime behavior.
                if (seen_count < 16) {
                    int len = libc::snprintf(&seen_key_buf[seen_count], 64, "%.17g", key_tok.num_value);
                    char[] num_str = seen_key_buf[seen_count][:len];
                    for (usz i = 0; i < seen_count; i++) {
                        if (str_eq(seen_key_buf[i][:seen_key_len[i]], num_str)) {
                            return COMPILE_ERROR~;
                        }
                    }
                    seen_key_len[seen_count] = (usz)len;
                    seen_count++;
                }

                uint key_idx = self.add_number_constant(key_tok.num_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.LBRACKET) {
                // Computed property key
                self.advance()!;
                key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
            } else if (self.match(TokenType.ELLIPSIS)) {
                // Object spread: ...expr
                ushort spread_reg = self.assignment_expr()!;
                self.emit_abc(Opcode.OBJSPRD, (uint)obj_reg, 0, (uint)spread_reg);
                self.free_reg(spread_reg);

                if (!self.match(TokenType.COMMA)) {
                    break;
                }
                continue;
            } else {
                return COMPILE_ERROR~;
            }

            // Check for method shorthand or data property
            if (self.check(TokenType.LPAREN)) {
                // Method shorthand: key() { ... }
                ushort method_reg = self.function_expr_body()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)method_reg);
                self.free_reg(method_reg);
                self.free_reg(key_reg);
            } else {
                // key: value
                self.expect(TokenType.COLON)!;
                ushort val_reg = self.assignment_expr()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                self.free_reg(val_reg);
                self.free_reg(key_reg);
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RBRACE)!;
    return obj_reg;
}

/// Parse array literal: [ expr, expr, ... ]
fn ushort? CompilerContext.array_literal(&self) {
    self.expect(TokenType.LBRACKET)!;

    ushort arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)arr_reg, 0, 0);

    // Track index: compile-time uint for normal arrays,
    // register-based when spread is used
    uint index = 0;
    ushort idx_reg = MAX_REGISTERS;
    bool has_spread = false;

    if (!self.check(TokenType.RBRACKET)) {
        for (;;) {
            if (self.check(TokenType.RBRACKET)) {
                break;
            }

            if (self.check(TokenType.COMMA)) {
                // Elision (hole in array)
                if (has_spread) {
                    ushort one = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    index++;
                }
                self.advance()!;
                continue;
            }

            // Check for spread
            if (self.match(TokenType.ELLIPSIS)) {
                ushort spread_reg = self.assignment_expr()!;

                if (!has_spread) {
                    // First spread: switch to register-based index
                    has_spread = true;
                    idx_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index));
                }

                // ARRSPRD: A=target_arr, B=idx_reg, C=source
                self.emit_abc(Opcode.ARRSPRD, (uint)arr_reg, (uint)idx_reg, (uint)spread_reg);
                self.free_reg(spread_reg);
            } else {
                ushort elem_reg = self.assignment_expr()!;

                if (has_spread) {
                    // Dynamic index: store at current idx_reg, then increment
                    self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_reg, (uint)elem_reg);
                    ushort one = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    // Compile-time index
                    ushort idx_const = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_const, (int)index));
                    self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_const, (uint)elem_reg);
                    self.free_reg(idx_const);
                    index++;
                }
                self.free_reg(elem_reg);
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set array length
    if (has_spread) {
        // Dynamic length: set arr["length"] = idx_reg
        uint len_const_idx = self.add_string_constant("length");
        ushort len_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)len_reg, len_const_idx));
        self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)len_reg, (uint)idx_reg);
        self.free_reg(len_reg);
    } else {
        self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)arr_reg, index));
    }

    self.expect(TokenType.RBRACKET)!;
    return arr_reg;
}

// ============================================================================
// String comparison helper
// ============================================================================

// ============================================================================
// for-of loop compilation
// ============================================================================

/// Emit bytecode for a for-of loop.  The iterable expression has already been
/// evaluated into `iter_reg` and the RParen was consumed.
/// Uses the ES6 iterator protocol: Symbol.iterator → .next() → {value, done}.
fn void? CompilerContext.emit_forof_loop(&self, char[] var_name, ushort iter_reg, uint saved_scope, ushort saved_reg, bool is_lexical, bool is_const, bool is_bare) {
    // Declare loop variable register
    ushort loop_var;
    if (is_bare) {
        loop_var = self.alloc_reg();
    } else {
        ScopeKind kind = is_const ? CONST : (is_lexical ? LET : VAR);
        loop_var = self.declare_var(var_name, kind);
    }

    uint name_idx = self.add_string_constant(var_name);

    // === Iterator Protocol ===

    // Step 1: Get Symbol.iterator method from iterable
    //   sym = GETVAR "Symbol"
    //   symbol_val = GETPROP sym, "iterator"   (the well-known symbol value)
    //   method = GETPROP iter_reg, symbol_val   (iterable[Symbol.iterator] → the method)
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);
    // symbol_val_reg holds the Symbol.iterator well-known symbol

    // Look up the method on the iterable using the symbol as property key
    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);
    // method_reg is top of register stack, holds iterable[Symbol.iterator]

    // Step 2: Call iterable[Symbol.iterator]() to get the iterator object
    //   this_slot = iter_reg            (this = iterable)
    //   CALL method_reg, method_reg, 0  (iterator = iterable[Symbol.iterator].call(iterable))
    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);
    // method_reg is top, now holds the iterator object

    // Step 3: Get .next method from iterator
    //   next_key = LDCONST "next"
    //   next = GETPROP iterator, next_key
    ushort next_reg = self.alloc_reg();
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);
    // next_reg is top (.next method), method_reg below (iterator)

    // Step 4: Set up callee + this pair for .next() calls
    //   callee = next_reg        (.next method)
    //   callee_this = method_reg (iterator, as this for .next())
    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

    // Loop start
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    // Step 5: Call .next() each iteration
    //   result = CALL callee, 0    (result = next.call(iterator))
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

    // Step 6: Extract .done
    //   done_key = LDCONST "done"
    //   done = GETPROP result, done_key
    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    // Step 7: Extract .value
    //   value_key = LDCONST "value"
    //   val = GETPROP result, value_key
    ushort value_key_reg = self.alloc_reg();
    ushort val_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

    // Step 8: Assign to loop variable
    self.emit_abc(Opcode.LDREG, (uint)loop_var, (uint)val_reg, 0);

    if (is_bare) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)loop_var, name_idx);
    } else {
        self.emit_var_store(loop_var, name_idx, is_lexical, is_const);
    }

    // Free loop-iteration temps (reverse order — stack discipline)
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // Step 9: Body
    self.statement()!;

    // Continue target: jump back to .next() call
    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;

    // Jump back to loop start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    // Free loop-overhead registers
    self.free_reg(callee_this_reg);
    self.free_reg(callee_reg);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}
