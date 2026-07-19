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
    // Comma discards References — clear call_prop_obj_reg after each operand,
    // including the rightmost one (comma always returns a value, not a Reference).
    // Per ES2015 §12.2.1.3 NamedEvaluation, only direct `= expr` assignments
    // receive inferred names — a comma-expression result does not. Clear the flag
    // so the rightmost operand of `(a, function(){})` never gets the outer name.
    while (self.match(TokenType.COMMA)) {
        self.free_reg(result);
        // Discard left operand's reference
        if (self.call_prop_obj_reg != MAX_REGISTERS) {
            self.free_reg(self.call_prop_obj_reg);
            self.call_prop_obj_reg = MAX_REGISTERS;
        }
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
        result = self.assignment_expr()!;
        // Discard rightmost operand's reference too
        if (self.call_prop_obj_reg != MAX_REGISTERS) {
            self.free_reg(self.call_prop_obj_reg);
            self.call_prop_obj_reg = MAX_REGISTERS;
        }
    }

    return result;
}

/// Save the raw text of a just-resolved identifier for later SetFunctionName
/// inference (assignment_expr reads this when the LHS is a simple
/// IdentifierReference). Truncates (clears) if the name doesn't fit.
fn void CompilerContext.save_lhs_ident_name(&self, char[] name) {
    if (name.len < 128) {
        for (ushort i = 0; i < name.len; i++) self.last_lhs_name_buf[i] = name[i];
        self.last_lhs_name_len = (ushort)name.len;
    } else {
        self.last_lhs_name_len = 0;
    }
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

    if (self.last_was_optional_chain) {
        if (g_last_err_msg[0] == 0) {
            g_last_err_line = self.lexer.line;
            g_last_err_col  = self.lexer.col;
            char[] msg = "Invalid left-hand side in assignment";
            usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
            libc::memcpy(&g_last_err_msg[0], msg.ptr, copy_len);
            g_last_err_msg[copy_len] = 0;
        }
        return COMPILE_ERROR~;
    }

    if (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var) {
        if (g_last_err_msg[0] == 0) {
            g_last_err_line = self.lexer.line;
            g_last_err_col  = self.lexer.col;
            char[] msg = "Invalid left-hand side in assignment";
            usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
            libc::memcpy(&g_last_err_msg[0], msg.ptr, copy_len);
            g_last_err_msg[copy_len] = 0;
        }
        return COMPILE_ERROR~;
    }

    // ES5 §11.13.1 strict mode: assigning to 'eval' or 'arguments' is a
    // SyntaxError. Only fires for a bare identifier target — member
    // expressions never reach here with last_lhs_name_len set
    // (save_lhs_ident_name is called only from identifier resolution).
    if (!self.last_was_member && self.last_lhs_name_len > 0
        && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len])) {
        return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
    }

    // Save LHS info (will be overwritten by RHS evaluation)
    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;
    bool lhs_was_member = self.last_was_member;
    ushort lhs_member_obj = self.last_member_obj_reg;
    ushort lhs_member_prop = self.last_member_prop_reg;
    bool lhs_was_local_var = self.last_was_local_var;
    // super.x stores go through PUTPROP_SUPER (receiver = this, §13.15.2).
    Opcode member_store_op = self.last_member_is_super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP;
    // Save the LHS identifier text for SetFunctionName (below) before it
    // gets clobbered by RHS parsing.
    char[128] lhs_ident_name_buf = self.last_lhs_name_buf;
    ushort lhs_ident_name_len = self.last_lhs_name_len;

    // Peek for a literal-1 RHS: `<var> -= 1` → DEC.
    // The `+= 1` optimization (INC) was removed because it bypasses ADD's
    // string-concatenation semantics: `"1" + 1` must yield `"11"`.
    // Saves a register + LDINT 1 instruction per occurrence (hot in counters).
    if (is_compound && !lhs_was_member) {
        if (self.peek_type() == TokenType.NUMBER) {
            Token num_tok2 = self.lexer.peek()!;
            double nv = num_tok2.num_value;
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
                        self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
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
            // x ||= expr: skip RHS if left is truthy.
            // For var targets: PUTVAR clears the source register, so we need a
            // stable result register that holds the final value on both paths.
            ushort lor_res = left;
            if (!lhs_was_member && lhs_was_getvar) {
                lor_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)lor_res, (uint)left, 0);
            }
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)lor_res);
            ushort right = self.assignment_expr()!;
            bool right_is_local_lor = self.last_was_local_var;
            if (lhs_was_member) {
                self.emit_abc(member_store_op, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                if (!right_is_local_lor) { self.free_reg(right); }
            } else {
                // Copy RHS into the result register, then store to env.
                self.emit_abc(Opcode.LDREG, (uint)lor_res, (uint)right, 0);
                if (!right_is_local_lor) { self.free_reg(right); }
                if (lhs_was_getvar) {
                    // PUTVAR reads from left (the GETVAR register) and clears it;
                    // lor_res already holds the value and is our result.
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)lor_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
                }
                la_result = lor_res;
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_logical_and_assign) {
            // x &&= expr: skip RHS if left is falsy.
            ushort land_res = left;
            if (!lhs_was_member && lhs_was_getvar) {
                land_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)land_res, (uint)left, 0);
            }
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)land_res);
            ushort right = self.assignment_expr()!;
            bool right_is_local_land = self.last_was_local_var;
            if (lhs_was_member) {
                self.emit_abc(member_store_op, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                if (!right_is_local_land) { self.free_reg(right); }
            } else {
                self.emit_abc(Opcode.LDREG, (uint)land_res, (uint)right, 0);
                if (!right_is_local_land) { self.free_reg(right); }
                if (lhs_was_getvar) {
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)land_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
                }
                la_result = land_res;
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_nullish_assign) {
            // x ??= expr: skip RHS if left is NOT null/undefined.
            // For var targets: allocate a stable result register before branching;
            // initialize it to left so the skip (non-nullish) path has a valid value.
            ushort nc_res = left;
            if (!lhs_was_member && lhs_was_getvar) {
                nc_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)nc_res, (uint)left, 0);
            }
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
            bool right_is_local_nc = self.last_was_local_var;
            if (lhs_was_member) {
                self.emit_abc(member_store_op, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                if (!right_is_local_nc) { self.free_reg(right); }
            } else {
                // Copy RHS into nc_res (the stable result reg), then store to env.
                self.emit_abc(Opcode.LDREG, (uint)nc_res, (uint)right, 0);
                if (!right_is_local_nc) { self.free_reg(right); }
                if (lhs_was_getvar) {
                    // PUTVAR clears its source; copy to left first, then write env.
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)nc_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
                }
                la_result = nc_res;
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
    }

    // Plain member assignment must not evaluate the LHS property read —
    // only the object and key are evaluated (§13.15.2).  Drop the GETPROP
    // (or GETPROP_CACHE / GETPROP_SUPER) emitted while parsing the target so
    // getters / proxy [[Get]] traps don't run as a side effect, and so any
    // GETPROP_CACHE key-coercion writeback doesn't run before RHS either
    // (`base[prop] = expr()` must ToPropertyKey(prop) AFTER expr()). For
    // super targets, this also defers the HomeObject null-prototype
    // TypeError: per spec MakeSuperPropertyReference computes [[Base]]
    // eagerly (never throws — GetSuperBase just returns null), but the
    // actual ToObject(base) check happens inside PutValue, AFTER the RHS has
    // been evaluated (§6.2.5.6). Stripping the eager read here means
    // PUTPROP_SUPER's own null-base check performs that throw at the
    // correct point, after RHS runs. Compound/logical assignments keep the
    // read (they genuinely need the old value, and rely on GETPROP_CACHE's
    // writeback for the follow-up PUTPROP to be idempotent).
    if (is_assign && lhs_was_member && self.code_count > 0) {
        Instruction lhs_last = self.code[self.code_count - 1];
        if ((lhs_last.op == Opcode.GETPROP || lhs_last.op == Opcode.GETPROP_CACHE)
            && (ushort)lhs_last.a == left
            && (ushort)lhs_last.b == lhs_member_obj && (ushort)lhs_last.c == lhs_member_prop) {
            self.code_count--;
        } else if (self.last_member_is_super) {
            // super.x / super[x] emits GETPROP_SUPER usually followed by an
            // LDTHIS (staged this-binding for a possible super method call).
            // Strip both so the null-proto check runs after RHS at PUTPROP_SUPER.
            uint scan_idx = self.code_count - 1;
            if (lhs_last.op == Opcode.LDTHIS && scan_idx > 0) {
                Instruction maybe_getpropsuper = self.code[scan_idx - 1];
                if (maybe_getpropsuper.op == Opcode.GETPROP_SUPER
                    && (ushort)maybe_getpropsuper.a == left
                    && (ushort)maybe_getpropsuper.b == lhs_member_obj
                    && (ushort)maybe_getpropsuper.c == lhs_member_prop) {
                    if (self.call_prop_obj_reg == (ushort)lhs_last.a) {
                        self.free_reg(self.call_prop_obj_reg);
                        self.call_prop_obj_reg = MAX_REGISTERS;
                    }
                    self.code_count -= 2;
                }
            } else if (lhs_last.op == Opcode.GETPROP_SUPER && (ushort)lhs_last.a == left
                && (ushort)lhs_last.b == lhs_member_obj && (ushort)lhs_last.c == lhs_member_prop) {
                self.code_count--;
            }
        }
    }

    // ES2015 §12.15.4 AssignmentExpression: `x = anonymousFn` — when the LHS
    // is a simple IdentifierReference (not a member expression), pass the
    // name through for NamedEvaluation of an anonymous function/class/arrow
    // RHS. Member-expression LHS (`o.attr = fn`) must NOT be named.
    if (is_assign && !lhs_was_member && (lhs_was_getvar || lhs_was_local_var)
        && lhs_ident_name_len > 0) {
        self.has_inferred_name = true;
        self.inferred_name_len = lhs_ident_name_len;
        for (ushort i = 0; i < lhs_ident_name_len; i++) {
            self.inferred_name_buf[i] = lhs_ident_name_buf[i];
        }
    }

    // Compile right-hand side
    ushort right = self.assignment_expr()!;
    // A bare identifier RHS that resolved to a live local variable's own
    // register (not a temp) must never be freed here — free_reg is LIFO and
    // would hand that exact register back out to the very next alloc_reg
    // (e.g. the callee lookup of a call in the following statement), silently
    // aliasing and clobbering the variable in place.
    bool right_is_local = self.last_was_local_var;

    if (is_assign) {
        if (lhs_was_member) {
            // Member expression assignment: obj.prop = right.
            // The GETPROP result reg (`left`) was allocated by member_expr but
            // stripped above; free it before repurposing `left` as the returned
            // value so tight compiles don't leak one temp per plain member
            // assignment.
            self.free_reg(left);
            self.emit_abc(member_store_op, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
            self.free_reg(lhs_member_prop);
            self.free_reg(lhs_member_obj);
            if (!right_is_local) { self.free_reg(right); }
            left = right;
        } else {
            // Simple assignment: left = right
            if (left != right) {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            }
            if (!right_is_local) { self.free_reg(right); }
            if (lhs_was_getvar) {
                // PUTVAR clears the source register, so save the value
                // in a temp before writing back to the environment.
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
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
        if (!right_is_local) { self.free_reg(right); }
        if (!lhs_was_getvar && !lhs_was_member && result_reg != left) {
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)result_reg, 0);
            self.free_reg(result_reg);
        }
        // If LHS was a member expression, write the new value back to the
        // property via PUTPROP. `left` (== result_reg in the member case)
        // holds the new value. This is what makes `obj.prop += rhs` and
        // `arr[i] += rhs` actually persist. The PUTPROP path takes
        // precedence over any stale `lhs_was_getvar` from an inner
        // identifier resolution (e.g. `globalC[0] += 5`).
        if (lhs_was_member) {
            self.emit_abc(member_store_op, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)left);
            self.free_reg(lhs_member_prop);
            self.free_reg(lhs_member_obj);
        } else if (lhs_was_getvar) {
            // PUTVAR clears the source register, so copy to a temp first
            // so the result survives the clobber.
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lhs_getvar_name_idx);
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
            // Result merges into `left`'s register — if that is a live local
            // variable register, copy to a temp first so the variable isn't
            // clobbered (same guard as the regular binary path below).
            if (left_is_local) {
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                left = tmp;
                left_is_local = false;
            }
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
            // Copy live local out of the merge register (see LOG_AND above).
            if (left_is_local) {
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                left = tmp;
                left_is_local = false;
            }
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
            // Copy live local out of the merge register (see LOG_AND above).
            if (left_is_local) {
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                left = tmp;
                left_is_local = false;
            }
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

    // Restore the local-var flag for the final `left` before returning: the
    // loop preamble unconditionally clears self.last_was_local_var on every
    // iteration (including the first, before checking precedence), so by the
    // time we reach `return` here it no longer reflects whether `left` is a
    // live local variable register. Callers (assignment_expr, postfix_expr,
    // unary_expr's prefix INC/DEC) rely on this flag to recognize a bare
    // local-variable operand (e.g. `len = 0`, `k++`) as a valid
    // SimpleAssignmentTarget alongside last_was_getvar/last_was_member.
    self.last_was_local_var = left_is_local;
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
            //
            // A parenthesized identifier (`typeof (x)`) is still an
            // IdentifierReference for this purpose — CoverParenthesizedExpression
            // doesn't change what gets evaluated, it only affects IsIdentifierRef
            // for NamedEvaluation/assignment-target purposes (ES2015 §12.5.7 has
            // no such carve-out). Detect the exact `( IDENTIFIER )` shape here (no
            // multi-token lookahead exists, so save/restore the lexer around a
            // speculative scan) and route it through the same fast path as a bare
            // identifier; anything else inside the parens falls through below.
            if (self.check(TokenType.LPAREN)) {
                uint saved_pos    = self.lexer.pos;
                uint saved_line   = self.lexer.line;
                uint saved_col    = self.lexer.col;
                Token saved_cur   = self.lexer.current;
                Token saved_look  = self.lexer.lookahead;
                bool  saved_haslk = self.lexer.has_lookahead;
                Token saved_push  = self.lexer.pushed_back;
                bool  saved_haspb = self.lexer.has_pushed_back;
                bool  saved_slt   = self.lexer.seen_line_term;

                self.advance()!;  // consume '('
                Token? id_opt = self.lexer.next_token();
                bool matched = false;
                Token matched_id;
                if (try idTok2 = id_opt) {
                    if (idTok2.type == TokenType.IDENTIFIER &&
                        !str_eq(idTok2.str_value, "true") &&
                        !str_eq(idTok2.str_value, "false") &&
                        !str_eq(idTok2.str_value, "null") &&
                        !str_eq(idTok2.str_value, "undefined")) {
                        Token? rparen_opt = self.lexer.next_token();
                        if (try rp = rparen_opt) {
                            if (rp.type == TokenType.RPAREN) {
                                matched = true;
                                matched_id = idTok2;
                            }
                        }
                    }
                }

                if (matched) {
                    Token idTok2 = matched_id;
                    if (!self.is_global) {
                        if (try local_reg = self.resolve_var(idTok2.str_value)) {
                            ushort res_typeof = self.alloc_reg();
                            self.emit_abc(Opcode.TYPEOF, (uint)res_typeof, (uint)local_reg, 0);
                            return res_typeof;
                        }
                    }
                    uint name_idx = self.add_string_constant(idTok2.str_value);
                    ushort res_typeof = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.TYPEOFIDENT, (uint)res_typeof, name_idx));
                    return res_typeof;
                }

                // Not the simple `( IDENTIFIER )` shape — restore and fall
                // through to normal typeof expr parsing.
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
                            // If the identifier resolves to a non-captured local
                            // register, the reference is always resolvable, so use
                            // the register-based TYPEOF instead of the env-walking
                            // TYPEOFIDENT. This keeps the local out of the function's
                            // env (register-resident locals optimization). Captured
                            // vars and globals still use TYPEOFIDENT (handles the
                            // unresolvable-reference case per ES5 §11.4.3).
                            if (!self.is_global) {
                                if (try local_reg = self.resolve_var(idTok.str_value)) {
                                    ushort res_typeof = self.alloc_reg();
                                    self.emit_abc(Opcode.TYPEOF, (uint)res_typeof, (uint)local_reg, 0);
                                    return res_typeof;
                                }
                            }
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
            // If the operand was a member expression (obj.prop / obj[idx]),
            // member_expr keeps the obj/prop registers live in case the
            // access is an assignment target (allocation order is obj, prop,
            // then op_typeof's GETPROP result, so obj is lowest on the stack).
            // typeof never assigns, so free prop/op_typeof and write the
            // TYPEOF result into obj's register (reusing the lowest of the
            // three) rather than allocating a new register on top — that
            // would sit above prop/obj and make freeing them no-ops, since
            // free_reg only pops the top of the LIFO register stack.
            if (self.last_was_member) {
                ushort obj_reg = self.last_member_obj_reg;
                ushort prop_reg = self.last_member_prop_reg;
                bool obj_is_local = self.last_member_obj_is_local;
                self.last_was_member = false;
                if (obj_is_local) {
                    // obj_reg is a live local variable (e.g. `typeof d.value`):
                    // it must NOT be clobbered — writing the TYPEOF result into
                    // it would corrupt the variable. In RHS mode member_expr has
                    // already freed prop_reg, leaving op_typeof (the GETPROP
                    // result) as the only owned temp on top of the stack, so
                    // write the result in-place there and return it.
                    self.emit_abc(Opcode.TYPEOF, (uint)op_typeof, (uint)op_typeof, 0);
                    return op_typeof;
                }
                self.emit_abc(Opcode.TYPEOF, (uint)obj_reg, (uint)op_typeof, 0);
                self.free_reg(op_typeof);
                self.free_reg(prop_reg);
                return obj_reg;
            }
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
            // void result is never a Reference — clear tracking so
            // `delete void x.prop` returns true instead of patching DELPROP.
            self.last_was_member = false;
            self.last_was_getvar = false;
            return res_void;

        case TokenType.DELETE:
            self.advance()!;
            // Parse operand with del_mode to track member expression (obj.prop).
            // member_expr emits GETPROP as usual; we patch it to DELPROP below.
            // We use del_mode (not lhs_mode) because expression() inside [bracket]
            // calls assignment_expr which resets lhs_mode.
            self.del_mode = true;
            self.last_was_member = false;
            self.last_was_getvar = false;
            ushort op_del = self.unary_expr()!;
            self.del_mode = false;

            if (self.last_was_member) {
                if (self.last_member_is_super) {
                    // ES2022 §13.5.1.2 step 5.b: delete super.x / delete super[x]
                    // always throws ReferenceError — super references are not deletable.
                    // The super expression (including key evaluation) has already run;
                    // now emit a THROW_REF to raise ReferenceError at runtime.
                    // Free the super base and key registers allocated during super parsing.
                    self.free_reg(self.last_member_prop_reg);
                    self.free_reg(self.last_member_obj_reg);
                    self.last_was_member = false;
                    self.last_member_is_super = false;
                    // Discard the GETPROP_SUPER result register; emit ReferenceError throw.
                    self.free_reg(op_del);
                    uint msg_idx = self.add_string_constant("Cannot delete a super property");
                    ushort err_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.THROW_REF, (uint)err_reg, msg_idx));
                    return err_reg;
                }
                // Patch the last emitted instruction from GETPROP (or
                // GETPROP_CACHE — computed keys always emit the _CACHE
                // variant from member_expr, see its LBRACKET branch) to
                // DELPROP. All three have identical register layout:
                // A = result, B = obj, C = key.
                uint last_idx = self.code_count;
                if (last_idx > 0) {
                    last_idx--;
                    Instruction last_insn = self.code[last_idx];
                    if (last_insn.op == Opcode.GETPROP || last_insn.op == Opcode.GETPROP_CACHE) {
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
            } else if (self.last_was_getvar) {
                // `delete IdentifierReference` — Annex B.3.1 (ES5 11.4.1 step 1):
                // strict mode rejects this as a SyntaxError. Sloppy mode runs
                // the deletion against the variable environment. Since this
                // engine is strict-only, we always reject.
                self.last_was_getvar = false;
                return self.fail("delete of an unqualified identifier in strict mode")~;
            } else {
                // Delete of a non-reference (literal, expression result, etc.).
                // ES6 §12.5.3.2 step 3: If Type(ref) is not Reference, return true.
                // The operand was evaluated as a value (not a property/var
                // reference), so per the runtime semantics we just return true.
                ushort t = self.alloc_reg();
                self.emit_abc(Opcode.LDTRUE, (uint)t, 0, 0);
                return t;
            }

        case TokenType.INC:
            // Prefix ++
            self.advance()!;
            self.lhs_mode = true;
            ushort op_inc = self.postfix_expr()!;
            self.lhs_mode = false;
            if (self.last_was_optional_chain) {
                return COMPILE_ERROR~;
            }
            if (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var) {
                return COMPILE_ERROR~;
            }
            // ES5 §11.4.4 strict mode: ++eval / ++arguments is a SyntaxError.
            if (!self.last_was_member && self.last_lhs_name_len > 0
                && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len])) {
                return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
            }
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
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)op_inc, inc_getvar_name_idx);
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
            if (self.last_was_optional_chain) {
                return COMPILE_ERROR~;
            }
            if (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var) {
                return COMPILE_ERROR~;
            }
            // ES5 §11.4.5 strict mode: --eval / --arguments is a SyntaxError.
            if (!self.last_was_member && self.last_lhs_name_len > 0
                && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len])) {
                return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
            }
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
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)op_dec, dec_getvar_name_idx);
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
    // ES5 §7.9.1 restricted productions: no LineTerminator is allowed between
    // the operand and a postfix ++/--. If one is present, ASI forces a
    // semicolon here, so ++/-- belongs to the *next* statement instead.
    bool nl_before_postfix_op = self.lexer.seen_line_term;
    // ES2024 §13.4.2/13.4.3 UpdateExpression: the operand must be a
    // SimpleAssignmentTarget. Calls (`f()`), dynamic imports (`import(x)`),
    // and other non-reference results are not — reject as an early
    // SyntaxError rather than silently discarding the increment/decrement.
    if ((tt == TokenType.INC || tt == TokenType.DEC) && !nl_before_postfix_op) {
        if (!self.last_was_member && !lhs_was_getvar && !self.last_was_local_var) {
            return COMPILE_ERROR~;
        }
        // ES5 §11.3.1/§11.3.2 strict mode: eval++ / arguments-- is a SyntaxError.
        if (!self.last_was_member && self.last_lhs_name_len > 0
            && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len])) {
            return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
        }
    }
    if (tt == TokenType.INC && !nl_before_postfix_op) {
        if (self.last_was_optional_chain) {
            return COMPILE_ERROR~;
        }
        self.advance()!;
        // Save original value and convert to ToNumeric (ES2020 §13.4.3.1):
        // BigInt passes through, other types coerce to Number.
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);
        self.emit_abc(Opcode.TONUMERIC, (uint)saved, (uint)saved, 0);

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
                self.emit_a_bc(Opcode.INC_VAR, (uint)operand, lhs_getvar_name_idx);
                self.emit_abc(Opcode.NOP, 0, 0, 0);
            } else {
                self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
            }
        }
        self.last_was_getvar = false;
        self.last_was_member = false;
        return saved;
    }

    if (tt == TokenType.DEC && !nl_before_postfix_op) {
        if (self.last_was_optional_chain) {
            return COMPILE_ERROR~;
        }
        self.advance()!;
        // Save original value and convert to ToNumeric (ES2020 §13.4.3.1):
        // BigInt passes through, other types coerce to Number.
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);
        self.emit_abc(Opcode.TONUMERIC, (uint)saved, (uint)saved, 0);

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
                self.emit_a_bc(Opcode.DEC_VAR, (uint)operand, lhs_getvar_name_idx);
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
    self.last_was_optional_chain = false;
    ushort callee = self.member_expr()!;

    // If member_expr saved a property object but next token is not a call,
    // free the object register now. Inside parenthesized expressions, defer
    // this decision to the paren handler (which sees what follows the parens).
    if (self.call_prop_obj_reg != MAX_REGISTERS
        && !self.inside_parens
        && !self.check(TokenType.LPAREN)
        && !self.check(TokenType.OPT_CHAIN)
        && !self.is_next_template()) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    // Optional chaining short-circuit jump tracking
    uint[16] opt_jump_addrs;
    int opt_jump_count = 0;

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
            // Template literal after optional chain is a SyntaxError (early error)
            if (opt_jump_count > 0) {
                self.fail("Template literal after optional chain is not supported");
                return COMPILE_ERROR~;
            }
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
            if (self.check(TokenType.HASH_IDENT)) {
                // f().#name — private field access on a call result.
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok2 = self.advance()!;
                ushort priv_prop_reg = self.emit_private_access(priv_tok2.str_value, callee)!;
                ushort priv_result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)priv_result, (uint)callee, (uint)priv_prop_reg);

                if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN) || self.is_next_template()) {
                    self.free_reg(priv_prop_reg);
                    self.last_was_member = false;
                    self.call_prop_obj_reg = callee;
                } else {
                    self.last_was_member = true;
                    self.last_member_is_super = false;
                    self.last_member_is_private = true;
                    self.last_member_obj_reg = callee;
                    self.last_member_prop_reg = priv_prop_reg;
                    self.call_prop_obj_reg = callee;
                }
                callee = priv_result;
                continue;
            }
            // Property access: callee.name
            char[] prop_str = self.read_property_name()!;
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);

            // A property access on a call result is itself a MemberExpression
            // and a valid assignment/update target (`f().x = v`, `f().x++`).
            // Record it so assignment_expr/postfix_expr can emit PUTPROP —
            // mirrors member_expr's DOT branch. The obj (callee) and prop
            // registers are kept live for the store; a following call
            // (`f().m()`) clears the flag and consumes obj as 'this' below.
            if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN) || self.is_next_template()) {
                // Call/template follows: this is not a target; keep obj as 'this'.
                self.free_reg(prop_reg);
                self.last_was_member = false;
                self.call_prop_obj_reg = callee;
            } else {
                self.last_was_member = true;
                self.last_member_is_super = false;
                self.last_member_is_private = false;
                self.last_member_obj_reg = callee;
                self.last_member_prop_reg = prop_reg;
                self.call_prop_obj_reg = callee;
            }
            callee = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed property access: callee[expr]
            ushort idx_reg = self.expression()!;
            self.expect(TokenType.RBRACKET)!;

            // This access may be reused as a compound/logical-assign or
            // postfix/prefix-increment target (`f()[k] += v`, `f()[k]++`),
            // which needs the ToPropertyKey-coerced key cached for an
            // idempotent follow-up PUTPROP (§7.1.19). Plain assignment
            // (`f()[k] = v`) strips this GETPROP before it ever executes
            // (see assignment_expr), so the writeback never fires for that
            // case — ordering is unaffected. GETPROP_CACHE writes the
            // coerced key back into idx_reg; shield a live-local key from
            // that mutation first.
            idx_reg = self.shield_computed_key(idx_reg);

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP_CACHE, (uint)result, (uint)callee, (uint)idx_reg);

            // Computed member on a call result — also a valid target
            // (`f()[k] = v`). See the DOT branch above.
            if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN)) {
                self.free_reg(idx_reg);
                self.last_was_member = false;
                self.call_prop_obj_reg = callee;
            } else {
                self.last_was_member = true;
                self.last_member_is_super = false;
                self.last_member_obj_reg = callee;
                self.last_member_prop_reg = idx_reg;
                self.call_prop_obj_reg = callee;
            }
            callee = result;
        } else if (self.match(TokenType.OPT_CHAIN)) {
            // Template literal after ?. is a SyntaxError
            if (self.is_next_template()) {
                self.fail("Template literal after optional chain is not supported");
                return COMPILE_ERROR~;
            }

            // Emit null/undefined check on callee for short-circuit
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)callee, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)callee, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

            opt_jump_addrs[opt_jump_count++] = null_jump;
            opt_jump_addrs[opt_jump_count++] = undef_jump;

            self.last_was_optional_chain = true;

            // Process the access following ?.
            if (self.check(TokenType.LPAREN)) {
                // a?.() — clear direct eval flag, optional chain calls are never direct eval
                self.callee_is_eval = false;
                callee = self.emit_call(callee)!;
                self.last_was_member = false;
                self.last_was_getvar = false;
            } else if (self.match(TokenType.LBRACKET)) {
                // a?.[expr] — result is never a referenceable member/target
                // (optional chains can't be assignment targets per spec), so
                // plain GETPROP suffices — no coerced-key cache needed.
                ushort idx_reg = self.expression()!;
                self.expect(TokenType.RBRACKET)!;

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)idx_reg);
                self.free_reg(idx_reg);

                self.last_was_member = false;
                self.last_was_getvar = false;
                // Save object for potential this binding (inner or outer call)
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = callee;
                callee = result;
            } else if (self.check(TokenType.HASH_IDENT)) {
                // a?.#name — short-circuits above on nullish `a`; on the live
                // path this is a normal (brand-checked) private field read.
                // Result is never a referenceable member/target, matching the
                // a?.prop case below.
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok3 = self.advance()!;
                ushort priv_prop_reg2 = self.emit_private_access(priv_tok3.str_value, callee)!;
                ushort priv_result2 = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)priv_result2, (uint)callee, (uint)priv_prop_reg2);
                self.free_reg(priv_prop_reg2);

                self.last_was_member = false;
                self.last_was_getvar = false;
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = callee;
                callee = priv_result2;
            } else {
                // a?.prop — result is never a referenceable member
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);

                ushort prop_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
                self.free_reg(prop_reg);

                self.last_was_member = false;
                self.last_was_getvar = false;
                // Save object for potential this binding (inner or outer call)
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = callee;
                callee = result;
            }
        } else {
            break;
        }
    }

    // Patch optional chaining short-circuit jumps
    if (opt_jump_count > 0) {
        uint skip = self.emit_jump(Opcode.JUMP);
        for (int i = 0; i < opt_jump_count; i++) {
            self.patch_jump(opt_jump_addrs[i]);
        }
        self.emit_abc(Opcode.LDUNDEF, (uint)callee, 0, 0);
        self.patch_jump(skip);
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

    // If the this slot or argument region overlaps with live registers,
    // move the callee to a free area first.  Otherwise the LDUNDEF for
    // 'this' (at callee_reg+1) would clobber a live value (e.g. resolve
    // held in r1 when callee_reg=0 and next_reg=2), and inner call arg
    // setup would clobber live values for nested calls.
    // Also move when the callee register is a named local's home register:
    // CALL writes the result to the callee base, which would destroy the
    // binding (e.g. `function f(){} f(); f();` with f's register at the top
    // of the stack — the first call's result clobbers f).
    if (callee_reg + 1 < self.next_reg || self.is_local_var_reg(callee_reg)) {
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
                    // Allocate the running-total register (in/out for SPREAD_ARG
                    // and the base offset for PUTARG). Initialize with the count
                    // of plain args emitted before the first spread.
                    total_count_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count));
                }

                // SPREAD_ARG: A=first_arg base reg, B=running-total reg (in/out;
                // the spread is written at first_arg + running_total and the
                // register is advanced by the number of elements produced),
                // C=source reg. This stacks multiple spreads (and interleaved
                // PUTARG args) in argument order.
                self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                self.free_reg(spread_reg);

                // Adjust next_reg past the worst-case spread area
                // (conservatively reserve space; actual count is only known at runtime)
                if (self.next_reg <= dest_start + 1) {
                    self.next_reg = dest_start + 2;
                }
            } else {
                ushort arg_reg = self.assignment_expr()!;
                if (has_spread) {
                    // Non-spread arg following a spread — destination
                    // slot depends on the runtime spread count held in
                    // total_count_reg. The new PUTARG opcode writes the
                    // value at regs[first_arg + total_count] and
                    // increments total_count.
                    self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                    self.free_reg(arg_reg);
                } else {
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
    uint[MAX_TEMPLATE_PARTS] raw_indices;
    bool[MAX_TEMPLATE_PARTS] part_invalid;
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
        raw_indices[0] = self.add_string_constant(str_tok.raw_value);
        part_invalid[0] = str_tok.has_invalid_escape;
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE) {
        // Legacy TEMPLATE token (should not normally appear, but handle gracefully)
        Token tmpl_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(tmpl_tok.str_value);
        raw_indices[0] = self.add_string_constant(tmpl_tok.raw_value);
        part_invalid[0] = false;
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE_HEAD) {
        // Template with substitutions: `text${expr}text${expr}text`
        Token head_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(head_tok.str_value);
        raw_indices[0] = self.add_string_constant(head_tok.raw_value);
        part_invalid[0] = head_tok.has_invalid_escape;
        part_count = 1;

        // Compile first expression, then consume its closing `}` and scan
        // the following template part (B23 fix: parser-driven close).
        expr_regs[0] = self.expression()!;
        expr_count = 1;
        self.expect(TokenType.RBRACE)!;
        Token next_tok = self.lexer.scan_template_after_expr()!;

        // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
        while (next_tok.type == TokenType.TEMPLATE_MIDDLE) {
            str_indices[part_count] = self.add_string_constant(next_tok.str_value);
            raw_indices[part_count] = self.add_string_constant(next_tok.raw_value);
            part_invalid[part_count] = next_tok.has_invalid_escape;
            part_count++;

            expr_regs[expr_count] = self.expression()!;
            expr_count++;

            self.expect(TokenType.RBRACE)!;
            next_tok = self.lexer.scan_template_after_expr()!;
        }

        if (next_tok.type != TokenType.TEMPLATE_TAIL) {
            return COMPILE_ERROR~;
        }
        str_indices[part_count] = self.add_string_constant(next_tok.str_value);
        raw_indices[part_count] = self.add_string_constant(next_tok.raw_value);
        part_invalid[part_count] = next_tok.has_invalid_escape;
        part_count++;
    } else {
        return COMPILE_ERROR~;
    }

    // === Site cache: constants[cache_idx] holds this call site's frozen
    // template object across every evaluation, shared by all closures
    // instantiated from the enclosing CompiledFunction (ES2015 §12.2.9.3
    // GetTemplateObject — the cache is per Parse Node, not per closure).
    // The slot starts as `undefined`; the first evaluation builds and
    // freezes the array, then stores it back with SETCONST.
    TVal undef_tv;
    undef_tv.set_undefined();
    uint cache_idx = self.add_constant(undef_tv);

    ushort tmpl_arr_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tmpl_arr_reg, cache_idx));
    ushort cache_test_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)cache_test_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)cache_test_reg, (uint)tmpl_arr_reg, (uint)cache_test_reg);
    uint cached_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cache_test_reg);
    self.free_reg(cache_test_reg);

    // === Build the template object array (cache miss) ===
    self.emit_abc(Opcode.NEWARR, (uint)tmpl_arr_reg, 0, 0);

    // Fill with string parts (cooked values; undefined for invalid escapes)
    for (uint i = 0; i < part_count; i++) {
        ushort elem_reg = self.alloc_reg();
        if (part_invalid[i]) {
            self.emit_abc(Opcode.LDUNDEF, (uint)elem_reg, 0, 0);
        } else {
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)elem_reg, str_indices[i]));
        }
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)idx_reg, (uint)elem_reg);
        self.free_reg(elem_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)tmpl_arr_reg, part_count));

    // Create raw array (uncooked source text of each part)
    ushort raw_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)raw_arr_reg, 0, 0);

    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, raw_indices[i]));
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)raw_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)raw_arr_reg, part_count));

    // Set .raw property on template array — a real but non-enumerable data
    // property (ES2015 §12.2.9.3 step 8: CreateDataProperty, then step 9
    // demotes it to non-writable/non-configurable via freeze below; own
    // enumerability is fixed at creation since freeze doesn't alter it).
    {
        uint raw_key_idx = self.add_string_constant("raw");
        ushort raw_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)raw_key_reg, raw_key_idx));
        self.emit_abc(Opcode.PUTPROP_NE, (uint)tmpl_arr_reg, (uint)raw_key_reg, (uint)raw_arr_reg);
        self.free_reg(raw_key_reg);
    }

    // Both arrays are frozen — non-configurable/non-writable integrity
    // level (ES2015 §12.2.9.3 steps 10-11).
    self.emit_abc(Opcode.FREEZEOBJ, (uint)raw_arr_reg, 0, 0);
    self.free_reg(raw_arr_reg);
    self.emit_abc(Opcode.FREEZEOBJ, (uint)tmpl_arr_reg, 0, 0);

    self.emit(bytecode::make_a_bc(Opcode.SETCONST, (uint)tmpl_arr_reg, cache_idx));

    self.patch_jump(cached_jump);

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

    ushort ctor_reg;

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
            ctor_reg = result_reg;
        } else {
            // Not 'target' — error
            return COMPILE_ERROR~;
        }
    } else {
        // Parse the constructor (could be member access)
        ctor_reg = self.member_expr()!;

        // Per ES2023 §13.3.1.1 (EvaluateNew): GetValue(constructor) happens
        // BEFORE argument evaluation. If the constructor is a local var and
        // an argument expression assigns to that same var, the assignment
        // would clobber our constructor register. Move the constructor to
        // a fresh register that is guaranteed not to alias any local var slot.
        ushort safe_ctor_reg = self.alloc_reg();
        if (ctor_reg != safe_ctor_reg) {
            self.emit_abc(Opcode.LDREG, (uint)safe_ctor_reg, (uint)ctor_reg, 0);
            ctor_reg = safe_ctor_reg;
        }

        // Args start right after constructor (same convention as emit_call)
        ushort first_arg = ctor_reg + 2;
        if (self.next_reg < first_arg) {
            self.next_reg = first_arg;
        }
        ushort arg_count = 0;
        bool has_spread = false;
        ushort total_count_reg = MAX_REGISTERS;

        if (self.match(TokenType.LPAREN)) {
            if (!self.check(TokenType.RPAREN)) {
                for (;;) {
                    if (self.match(TokenType.ELLIPSIS)) {
                        ushort dest_start = first_arg + arg_count;
                        if (self.next_reg <= dest_start + 1) {
                            self.next_reg = dest_start + 2;
                        }
                        ushort spread_reg = self.assignment_expr()!;
                        if (spread_reg >= dest_start) {
                            ushort safe_reg = self.alloc_reg();
                            self.emit_abc(Opcode.LDREG, (uint)safe_reg, (uint)spread_reg, 0);
                            self.free_reg(spread_reg);
                            spread_reg = safe_reg;
                        }
                        if (!has_spread) {
                            has_spread = true;
                            total_count_reg = self.alloc_reg();
                            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count));
                        }
                        self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                        self.free_reg(spread_reg);
                        if (self.next_reg <= dest_start + 1) {
                            self.next_reg = dest_start + 2;
                        }
                    } else {
                        ushort arg_reg = self.assignment_expr()!;
                        if (has_spread) {
                            self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                            self.free_reg(arg_reg);
                        } else {
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
                    }

                    if (!self.match(TokenType.COMMA)) {
                        break;
                    }
                    if (self.check(TokenType.RPAREN)) {
                        break;
                    }
                }
            }
            self.expect(TokenType.RPAREN)!;
        }

        // Emit NEW_OBJ or NEW_OBJ_S (spread variant).
        if (has_spread) {
            self.emit_abc(Opcode.NEW_OBJ_S, (uint)ctor_reg, (uint)ctor_reg, (uint)total_count_reg);
        } else {
            self.emit_abc(Opcode.NEW_OBJ, (uint)ctor_reg, (uint)ctor_reg, (uint)arg_count);
        }

        self.free_regs_to(ctor_reg);
        self.next_reg = ctor_reg + 1;
        if (self.next_reg > self.max_reg) {
            self.max_reg = self.next_reg;
        }
    } // end else (non-new.target path)

    // Handle trailing member access, optional chaining, and calls:
    // new X().prop, new X()[idx], new X().method(), new D(99)?.a, new.target?.()
    // Reset member tracking: only a trailing property access (not a call) that is
    // the *last* thing parsed here should leave last_was_member set, so an outer
    // assignment (`new X().p = v`) emits a PUTPROP that runs setters, rather than
    // treating the read result as a discardable value.
    self.last_was_member = false;
    for (;;) {
        if (self.match(TokenType.OPT_CHAIN)) {
            // Template literal after ?. is a SyntaxError
            if (self.is_next_template()) {
                self.fail("Template literal after optional chain is not supported");
                return COMPILE_ERROR~;
            }

            // Emit null/undefined check for short-circuit
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)ctor_reg, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)ctor_reg, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

            self.last_was_optional_chain = true;

            if (self.check(TokenType.LPAREN)) {
                // new X()?.()
                self.callee_is_eval = false;
                self.call_prop_obj_reg = MAX_REGISTERS;
                ctor_reg = self.emit_call(ctor_reg)!;
                self.last_was_member = false;
                self.last_was_getvar = false;
            } else if (self.match(TokenType.LBRACKET)) {
                // new X()?.[expr]
                ushort idx_reg = self.expression()!;
                self.expect(TokenType.RBRACKET)!;
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)ctor_reg, (uint)idx_reg);
                self.free_reg(idx_reg);
                self.last_was_member = false;
                self.last_was_getvar = false;
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
            } else {
                // new X()?.prop
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);
                ushort prop_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)ctor_reg, (uint)prop_reg);
                self.free_reg(prop_reg);
                self.last_was_member = false;
                self.last_was_getvar = false;
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
            }

            // Patch short-circuit jumps
            uint skip = self.emit_jump(Opcode.JUMP);
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);
            self.emit_abc(Opcode.LDUNDEF, (uint)ctor_reg, 0, 0);
            self.patch_jump(skip);
        } else if (self.match(TokenType.DOT)) {
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
            // Check if this is a method call: new X().method(args)
            if (self.check(TokenType.LPAREN)) {
                self.last_was_member = false;
                self.free_reg(prop_reg);
                // Keep ctor_reg alive as 'this' for the method call
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
                ctor_reg = self.emit_call(ctor_reg)!;
            } else {
                // Record member info so an enclosing assignment can PUTPROP.
                // Keep obj (ctor_reg) and prop_reg alive; assignment_expr frees
                // them after emitting the store (mirrors member_expr's lhs path).
                self.last_was_member = true;
            self.last_member_is_super = false;
                self.last_member_obj_reg = ctor_reg;
                self.last_member_prop_reg = prop_reg;
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
            }
        } else if (self.match(TokenType.LBRACKET)) {
            ushort saved_prop_obj = self.call_prop_obj_reg;
            ushort idx_reg = self.expression()!;
            self.call_prop_obj_reg = saved_prop_obj;
            self.expect(TokenType.RBRACKET)!;
            // May be reused as a compound/logical-assign or postfix/prefix
            // target (`new X()[k] += v`) — see call_expr's LBRACKET branch
            // for why GETPROP_CACHE + shield is needed here.
            idx_reg = self.shield_computed_key(idx_reg);
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP_CACHE, (uint)result, (uint)ctor_reg, (uint)idx_reg);
            // Check if this is a method call: new X()[idx](args)
            if (self.check(TokenType.LPAREN)) {
                self.last_was_member = false;
                self.free_reg(idx_reg);
                // Keep ctor_reg alive as 'this' for the method call
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
                ctor_reg = self.emit_call(ctor_reg)!;
            } else {
                self.last_was_member = true;
            self.last_member_is_super = false;
                self.last_member_obj_reg = ctor_reg;
                self.last_member_prop_reg = idx_reg;
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
                self.next_reg = ctor_reg + 1;
            }
        } else if (self.check(TokenType.LPAREN)) {
            // Trailing call on the freshly constructed object: `new X()(args)`.
            // Throws TypeError at runtime if X isn't callable (ES §13.3.1.1 step 10).
            self.call_prop_obj_reg = MAX_REGISTERS;
            ctor_reg = self.emit_call(ctor_reg)!;
            self.last_was_member = false;
            self.last_was_getvar = false;
        } else {
            break;
        }
    }

    // The result of a `new` expression is never a Reference (ES2024 §13.3.5).
    // Clear last_was_getvar so `delete new X()` correctly returns true
    // instead of rejecting as "delete of unqualified identifier".
    self.last_was_getvar = false;
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
    // Whether `obj` is still the bare base operand (not yet replaced by a
    // GETPROP result temp). Only the base can be a live local register; once
    // a `.prop`/`[idx]` step runs, `obj` becomes a fresh temp.
    bool obj_is_base_local = self.last_was_local_var;

    for (;;) {
        if (self.match(TokenType.DOT)) {
            // Member access (obj.prop) — not a direct identifier reference,
            // so clear the direct eval flag.
            self.callee_is_eval = false;

            if (self.check(TokenType.HASH_IDENT)) {
                // obj.#name — private field access. `delete obj.#x` is a
                // SyntaxError (early error; not a runtime concern here).
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok = self.advance()!;
                ushort prop_reg = self.emit_private_access(priv_tok.str_value, obj)!;

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)prop_reg);

                self.last_was_member = true;
                self.last_member_is_super = false;
                self.last_member_is_private = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = prop_reg;
                self.last_member_obj_is_local = obj_is_base_local;

                if (self.lhs_mode) {
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                    }
                    self.call_prop_obj_reg = obj;
                } else {
                    TokenType priv_next_tt = self.peek_type();
                    bool priv_is_postfix = (priv_next_tt == TokenType.INC || priv_next_tt == TokenType.DEC);
                    if (!priv_is_postfix) {
                        self.free_reg(prop_reg);
                    }
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                    }
                    self.call_prop_obj_reg = priv_is_postfix ? MAX_REGISTERS : obj;
                }

                obj = result;
                obj_is_base_local = false;
                continue;
            }

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
            self.last_member_is_super = false;
            self.last_member_is_private = false;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = prop_reg;
            self.last_member_obj_is_local = obj_is_base_local;

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/prop alive for possible PUTPROP/DELPROP
                // Also set up for potential method call 'this'. Always save obj
                // for this-binding — it will be freed by assignment_expr cleanup
                // if no call follows, or consumed by emit_call/emit_tagged_template.
                TokenType next_tt = self.peek_type();
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (next_tt == TokenType.LPAREN || next_tt == TokenType.OPT_CHAIN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else {
                    // Save for potential this-binding through parenthesized expressions
                    // (e.g. (a.b)?.()). assignment_expr cleanup will free last_member_obj_reg,
                    // but call_prop_obj_reg propagates through parens.
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free prop_reg immediately, UNLESS the next token is
                // a postfix INC/DEC — in that case postfix_expr needs prop alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free it.
                // Always save obj as call_prop_obj_reg for potential this-binding
                // (e.g. parenthesized expressions followed by a call).
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(prop_reg);
                }
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (is_postfix) {
                    // Postfix: keep obj alive for postfix_expr (via last_member_obj_reg)
                    self.call_prop_obj_reg = MAX_REGISTERS;
                } else {
                    // Non-postfix: save obj for potential this-binding.
                    // It will be freed when consumed (emit_call / emit_tagged_template)
                    // or freed by call_expr start check / LPAREN handler cleanup.
                    self.call_prop_obj_reg = obj;
                }
            }
            obj = result;
            obj_is_base_local = false;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed member access — not a direct identifier reference.
            self.callee_is_eval = false;
            // Save lhs_mode: the inner expression() calls assignment_expr()
            // which resets lhs_mode to false, clobbering the outer mode.
            bool saved_lhs = self.lhs_mode;
            ushort idx_reg = self.expression()!;
            self.lhs_mode = saved_lhs;
            self.expect(TokenType.RBRACKET)!;

            // This access may be reused as a compound/logical-assign or
            // postfix/prefix-increment target (`obj[k] += v`, `obj[k]++`),
            // which needs the ToPropertyKey-coerced key cached in idx_reg for
            // an idempotent follow-up PUTPROP (§7.1.19). Plain assignment
            // (`obj[k] = v`) strips this GETPROP before it ever executes
            // (see assignment_expr's plain-assign path), so the writeback
            // never fires for that case and evaluation order (ToPropertyKey
            // after RHS) is unaffected. Shield a live-local key from the
            // writeback mutation.
            idx_reg = self.shield_computed_key(idx_reg);

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP_CACHE, (uint)result, (uint)obj, (uint)idx_reg);

            // See DOT branch above for why we always track the member.
            self.last_was_member = true;
            self.last_member_is_super = false;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = idx_reg;
            self.last_member_obj_is_local = obj_is_base_local;

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/idx alive for possible PUTPROP/DELPROP
                // Always save obj for this-binding as well.
                TokenType next_tt2 = self.peek_type();
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (next_tt2 == TokenType.LPAREN || next_tt2 == TokenType.OPT_CHAIN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free idx_reg immediately, UNLESS the next token is
                // a postfix INC/DEC — in that case postfix_expr needs idx_reg alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free it.
                // Always save obj as call_prop_obj_reg for potential this-binding.
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(idx_reg);
                }
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (is_postfix) {
                    self.call_prop_obj_reg = MAX_REGISTERS;
                } else {
                    self.call_prop_obj_reg = obj;
                }
            }
            obj = result;
            obj_is_base_local = false;
        } else if (self.is_next_template()) {
            // MemberExpression : MemberExpression TemplateLiteral — a tagged
            // template is itself a MemberExpression (distinct from a call
            // expression's `Arguments`), so `new tag\`...\`` evaluates the
            // tagged template first and applies `new` to its result.
            obj = self.emit_tagged_template(obj)!;
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
            self.last_was_member = false;
            obj_is_base_local = false;
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

        case TokenType.BIGINT:
            self.last_was_getvar = false;
            Token bi_tok = self.advance()!;
            uint bi_idx = self.add_bigint_constant(bi_tok.str_value)!;
            ushort bi_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)bi_reg, bi_idx));
            return bi_reg;

        case TokenType.STRING:
            Token str_tok = self.advance()!;

            // Legacy octal escape sequences in strings are SyntaxErrors
            // per ES5 §7.8.4 + Annex B.1.2.
            if (str_tok.has_octal_escape) {
                return COMPILE_ERROR~;
            }
            if (str_tok.is_template && str_tok.has_invalid_escape) {
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
                // identifier and delegate to function_expr.
                if (self.peek_type() == TokenType.IDENTIFIER &&
                    self.match_async_function()) {
                    return self.function_expr(true)!;
                }

                // Detect async arrow functions: `async x => ...` or
                // `async (params) => ...`. Reuses the existing arrow-detection
                // logic in primary_expr by consuming `async` and re-entering
                // this function with is_async set, so it falls straight into
                // the IDENTIFIER-ARROW or LPAREN-speculative-arrow cases below.
                // We record the `async` keyword's source offset so the retained
                // source span starts there (ES2019 §19.2.3.5).
                // Capture `async`'s source offset here, after match_async_function()
                // left token_start = pos(async) as a side effect of consuming then
                // re-pushing the `async` token.  is_async_arrow_lookahead() may scan
                // further tokens and clobber token_start, so we save it first.
                uint pre_check_src = self.lexer.token_start;
                if (self.check(TokenType.IDENTIFIER) && self.is_async_arrow_lookahead()) {
                    uint async_src = pre_check_src;
                    self.advance()!;  // consume 'async'
                    // The arrow parsers read pending_async_arrow_src as the
                    // async signal; is_async is left alone so the enclosing
                    // body's flag (async function or TLA module) survives.
                    self.pending_async_arrow_src = async_src;
                    ushort r = self.primary_expr()!;
                    self.pending_async_arrow_src = 0xFFFFFFFF;
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
                    // Capture byte offset of the IDENTIFIER (just consumed) — the
                    // source for the arrow head runs from here to its body.
                    uint ident_arrow_src = self.lexer.token_start;
                    return self.parse_arrow_function(&params_arr[0], 1, false, ident_arrow_src)!;
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
                        self.save_lhs_ident_name(id_tok.str_value);
                        return var_reg;
                    }
                }

                // When 'arguments' is referenced inside a non-arrow function body,
                // set the uses_arguments flag so the VM creates the arguments object.
                if (str_eq(id_tok.str_value, "arguments") && !self.is_global) {
                    if (self.forbid_arguments) {
                        return self.fail("'arguments' is not allowed in class field initializer")~;
                    }
                    self.uses_arguments = true;
                }

                // Not found locally: emit GETVAR to look up by name at runtime
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                self.save_lhs_ident_name(id_tok.str_value);
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

            // Capture the byte offset of the opening `(` BEFORE the speculative
            // scan clobbers lexer.token_start with later tokens. Used downstream
            // for Function.prototype.toString source-text retention.
            uint lparen_pos = self.lexer.token_start;

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
            bool saved_inside_parens = self.inside_parens;
            self.inside_parens = true;

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
                    self.inside_parens = saved_inside_parens;
                    return self.parse_arrow_function_reparse(lparen_pos)!;
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
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                TokenType next_tt = self.peek_type();
                if (next_tt != TokenType.LPAREN && next_tt != TokenType.OPT_CHAIN) {
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                        self.call_prop_obj_reg = MAX_REGISTERS;
                    }
                }
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Clear the saved LHS name so assignment_expr's
                // SetFunctionName check (which also requires !lhs_was_member)
                // doesn't fire for a grouped identifier.
                self.last_lhs_name_len = 0;
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

                    // A parameter may also be a destructuring pattern, e.g.
                    // (x, [b]) => ... or (x, {c} = {}) => ... — skip over it
                    // (handling nesting) rather than bailing, so mixed
                    // identifier/destructured param lists are still detected
                    // as arrow functions. The skipped pattern's bindings
                    // don't need to be tracked here: once `is_arrow` is
                    // confirmed, parse_arrow_function_reparse() re-parses
                    // the whole param list from source.
                    if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                        self.advance()!;
                        self.skip_destructure_pattern();
                    } else {
                        Token t = self.advance()!;
                        if (t.type != TokenType.IDENTIFIER) {
                            break;  // not a param name, can't be arrow
                        }
                        param_names[pc++] = t.str_value;
                    }

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
                    self.inside_parens = saved_inside_parens;
                    return self.parse_arrow_function_reparse(lparen_pos)!;
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
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                TokenType next_tt = self.peek_type();
                if (next_tt != TokenType.LPAREN && next_tt != TokenType.OPT_CHAIN) {
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                        self.call_prop_obj_reg = MAX_REGISTERS;
                    }
                }
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Clear the saved LHS name so assignment_expr's
                // SetFunctionName check (which also requires !lhs_was_member)
                // doesn't fire for a grouped identifier.
                self.last_lhs_name_len = 0;
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
                    self.inside_parens = saved_inside_parens;
                    return self.parse_arrow_function_reparse(lparen_pos)!;
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
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                TokenType next_tt = self.peek_type();
                if (next_tt != TokenType.LPAREN && next_tt != TokenType.OPT_CHAIN) {
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                        self.call_prop_obj_reg = MAX_REGISTERS;
                    }
                }
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Clear the saved LHS name so assignment_expr's
                // SetFunctionName check (which also requires !lhs_was_member)
                // doesn't fire for a grouped identifier.
                self.last_lhs_name_len = 0;
                return inner2;
            } else {
                // Not arrow: parse as grouping expression
                ushort inner2 = self.expression()!;
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                TokenType next_tt = self.peek_type();
                if (next_tt != TokenType.LPAREN && next_tt != TokenType.OPT_CHAIN) {
                    if (self.call_prop_obj_reg != MAX_REGISTERS) {
                        self.free_reg(self.call_prop_obj_reg);
                        self.call_prop_obj_reg = MAX_REGISTERS;
                    }
                }
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Clear the saved LHS name so assignment_expr's
                // SetFunctionName check (which also requires !lhs_was_member)
                // doesn't fire for a grouped identifier.
                self.last_lhs_name_len = 0;
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
            if (!self.is_generator) {
                // Outside generators, `yield` is just an identifier per
                // ES2024 §13.1.1. Handle it via the standard identifier
                // path — same pattern as the AWAIT case when !is_async.
                Token id_tok = self.advance()!;
                if (self.check(TokenType.ARROW)) {
                    char[][1] params_arr;
                    params_arr[0] = id_tok.str_value;
                    uint ident_arrow_src = self.lexer.token_start;
                    return self.parse_arrow_function(&params_arr[0], 1, false, ident_arrow_src)!;
                }
                self.callee_is_eval = str_eq(id_tok.str_value, "eval");
                if (!self.is_global) {
                    if (try var_reg = self.resolve_var(id_tok.str_value)) {
                        self.last_was_getvar = false;
                        self.last_was_local_var = true;
                        self.last_local_var_reg = var_reg;
                        self.save_lhs_ident_name(id_tok.str_value);
                        return var_reg;
                    }
                }
                if (str_eq(id_tok.str_value, "arguments") && !self.is_global) {
                    if (self.forbid_arguments) {
                        return self.fail("'arguments' is not allowed in class field initializer")~;
                    }
                    self.uses_arguments = true;
                }
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                self.save_lhs_ident_name(id_tok.str_value);
                return id_reg;
            }
            self.advance()!;  // consume 'yield'
            // ES2015 §14.4 YieldExpression: `yield [no LineTerminator here] *`
            // and `yield [no LineTerminator here] AssignmentExpression` — a
            // LineTerminator right after `yield` forces the bare `yield`
            // (yields undefined), same as ASI restricted productions.
            // `seen_line_term` reflects whitespace scanned *before* the most
            // recently produced token, so force the lookahead scan (via
            // peek_type) before reading it — otherwise it's stale from
            // before `yield` itself (see postfix_expr's nl_before_postfix_op
            // for the same pattern).
            self.peek_type();
            bool nl_after_yield = self.lexer.seen_line_term;
            // Check for yield* (delegating yield)
            bool is_delegate = false;
            if (!nl_after_yield && self.match(TokenType.STAR)) {
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
                if (nl_after_yield || self.check(TokenType.SEMICOLON) || self.check(TokenType.RBRACE)
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
        // In script (non-module) code, `await` is just an IdentifierName per
        // ES2024 §13.1.1 — only the operator in async functions. Outside of
        // an async function (and outside a module) `await` is an identifier,
        // so handle it via the standard identifier-as-expression path:
        // resolve as a local variable if possible, else emit GETVAR.
        case TokenType.AWAIT:
        {
            if (!self.is_async) {
                // In a module, `await` is always reserved (ES2024 §13.1.1) —
                // it is never a plain IdentifierName, even outside an async
                // function. Reject rather than treating it as an identifier.
                if (self.is_module) {
                    return COMPILE_ERROR~;
                }
                Token id_tok = self.advance()!;
                if (self.check(TokenType.ARROW)) {
                    // `await => ...` could be an arrow function with one
                    // identifier parameter named "await".
                    char[][1] params_arr;
                    params_arr[0] = id_tok.str_value;
                    uint ident_arrow_src = self.lexer.token_start;
                    return self.parse_arrow_function(&params_arr[0], 1, false, ident_arrow_src)!;
                }
                // Resolve via the standard identifier path: local var lookup,
                // else runtime GETVAR. Same semantics as the IDENTIFIER branch.
                self.callee_is_eval = str_eq(id_tok.str_value, "eval");
                if (!self.is_global) {
                    if (try var_reg = self.resolve_var(id_tok.str_value)) {
                        self.last_was_getvar = false;
                        self.last_was_local_var = true;
                        self.last_local_var_reg = var_reg;
                        self.save_lhs_ident_name(id_tok.str_value);
                        return var_reg;
                    }
                }
                if (str_eq(id_tok.str_value, "arguments") && !self.is_global) {
                    if (self.forbid_arguments) {
                        return self.fail("'arguments' is not allowed in class field initializer")~;
                    }
                    self.uses_arguments = true;
                }
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                self.save_lhs_ident_name(id_tok.str_value);
                return id_reg;
            }
            self.advance()!;  // consume 'await'
            ushort operand = self.unary_expr()!;
            // AWAIT suspends the async function; LOAD_RESUME loads the settled value
            self.emit_abc(Opcode.AWAIT, (uint)operand, 0, 0);
            self.emit_abc(Opcode.LOAD_RESUME, (uint)operand, 0, 0);
            return operand;
        }

        // `import(...)` — dynamic import expression (ES2020).
        case TokenType.IMPORT:
        {
            self.advance()!;  // consume 'import'
            if (!self.match(TokenType.LPAREN)) {
                return self.fail("'import' as an expression must be followed by '(' (dynamic import)")~;
            }
            ushort spec_reg = self.assignment_expr()!;
            // Optional second argument: import(specifier, options).
            // Per ES2025 the options AssignmentExpression IS evaluated (it
            // may have side effects, e.g. an awaited expression), but full
            // import-attribute semantics (applying `with: {type: ...}`) are
            // deferred — the result is simply discarded here.
            if (self.match(TokenType.COMMA)) {
                if (!self.check(TokenType.RPAREN)) {
                    ushort options_reg = self.assignment_expr()!;
                    self.free_reg(options_reg);
                    // Allow a further trailing comma: import(x, opts,)
                    self.match(TokenType.COMMA);
                }
            }
            self.expect(TokenType.RPAREN)!;
            self.free_reg(spec_reg);
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.DYN_IMPORT, (uint)result, (uint)spec_reg, 0);
            // ImportCall produces a value, not a Reference (ES2024 §13.3.10):
            // it is not a SimpleAssignmentTarget. Clear the same flags a call
            // expression clears after emit_call so the assignment/update
            // target checks reject `import(x)++`, `++import(x)`, and
            // `import(x) = v` the same way they already reject `f()++`.
            self.last_was_member = false;
            self.last_was_getvar = false;
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
                bool has_spread = false;
                ushort total_count_reg = MAX_REGISTERS;
                if (!self.check(TokenType.RPAREN)) {
                    for (;;) {
                        // Spread argument: super(...iterable) — same lowering
                        // as emit_call (SPREAD_ARG + runtime count register).
                        if (self.match(TokenType.ELLIPSIS)) {
                            ushort dest_start = first_arg + arg_count;
                            if (self.next_reg <= dest_start + 1) {
                                self.next_reg = dest_start + 2;
                            }
                            ushort spread_reg = self.assignment_expr()!;
                            if (spread_reg >= dest_start && spread_reg <= dest_start + 10) {
                                ushort safe_reg = self.alloc_reg();
                                self.emit_abc(Opcode.LDREG, (uint)safe_reg, (uint)spread_reg, 0);
                                self.free_reg(spread_reg);
                                spread_reg = safe_reg;
                            }
                            if (!has_spread) {
                                has_spread = true;
                                total_count_reg = self.alloc_reg();
                                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count));
                            }
                            self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                            self.free_reg(spread_reg);
                            if (self.next_reg <= dest_start + 1) {
                                self.next_reg = dest_start + 2;
                            }
                        } else {
                            ushort arg_reg = self.assignment_expr()!;
                            if (has_spread) {
                                // Slot depends on the runtime spread count.
                                self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                                self.free_reg(arg_reg);
                            } else {
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

                // Place 'this' slot — use LDUNDEF as a placeholder; SUPER_CALL
                // allocates the actual new object (OrdinaryCreateFromConstructor)
                // using new.target.prototype and ignores this slot.
                self.emit_abc(Opcode.LDUNDEF, (uint)(super_reg + 1), 0, 0);

                // Emit SUPER_CALL / SUPER_CALL_S, reusing super_reg as result
                if (has_spread) {
                    self.emit_abc(Opcode.SUPER_CALL_S, (uint)super_reg, (uint)super_reg, (uint)total_count_reg);
                } else {
                    self.emit_abc(Opcode.SUPER_CALL, (uint)super_reg, (uint)super_reg, (uint)arg_count);
                }

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
                // super.x / super[x] is syntactically valid in any class method or
                // object-literal method, even without `extends`. The runtime raises
                // a ReferenceError/TypeError when GetSuperBase returns undefined/null.
                if (!self.has_super_binding && !self.in_class_body && !self.super_is_home_object) {
                    return COMPILE_ERROR~;
                }

                // Helper macro-inline: compute super base into super_proto_reg.
                // Defined here so both DOT and LBRACKET branches can call it after
                // key evaluation (important for super[expr]: key must be evaluated
                // BEFORE GetSuperBase per §13.5.3 Runtime Semantics).
                ushort super_proto_reg = MAX_REGISTERS;

                // For super.x (DOT), the key is compile-time constant so we can
                // compute the super base first (no observable ordering difference).
                // For super[expr] (LBRACKET), the spec requires evaluating the key
                // expression before checking/accessing the super base.
                ushort result;
                ushort super_key_reg;
                if (self.match(TokenType.DOT)) {
                    // DOT: compute super base first, then emit constant key.
                    // Static methods' HomeObject is the constructor itself
                    // (__static_super__, always via GETPROTO) — see §13.3.7.1.
                    uint super_name_idx = self.super_is_static_method
                        ? self.add_string_constant("__static_super__")
                        : self.add_string_constant("__super__");
                    ushort super_ctor_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_ctor_reg, super_name_idx));
                    if (self.super_is_static_method || self.super_is_home_object) {
                        super_proto_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROTO, (uint)super_proto_reg, (uint)super_ctor_reg, 0);
                        self.free_reg(super_ctor_reg);
                    } else {
                        uint proto_name_idx = self.add_string_constant("prototype");
                        ushort proto_key_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
                        super_proto_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROP, (uint)super_proto_reg, (uint)super_ctor_reg, (uint)proto_key_reg);
                        self.free_reg(proto_key_reg);
                        self.free_reg(super_ctor_reg);
                    }
                    char[] prop_str = self.read_property_name()!;
                    uint prop_idx = self.add_string_constant(prop_str);
                    super_key_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)super_key_reg, prop_idx));
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP_SUPER, (uint)result, (uint)super_proto_reg, (uint)super_key_reg);
                } else {
                    // LBRACKET: §13.3.7.1 step 2 requires GetThisBinding() BEFORE
                    // evaluating the key expression — in a derived constructor
                    // `this` is TDZ-sentinel until super() returns, so
                    // `super[super()]` must throw ReferenceError from the *outer*
                    // super's this-check, not from evaluating the key. Emit a
                    // throwaway LDTHIS purely for its TDZ side effect.
                    ushort this_check_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDTHIS, (uint)this_check_reg, 0, 0);
                    self.free_reg(this_check_reg);
                    // Evaluate key expression (spec §13.5.3 step 3-4), THEN
                    // compute the super base (step 4 MakeSuperPropertyReference).
                    self.advance()!;  // consume '['
                    super_key_reg = self.expression()!;
                    self.expect(TokenType.RBRACKET)!;
                    // Now compute super base. Static methods use __static_super__
                    // (the constructor) always via GETPROTO — see the DOT branch above.
                    uint super_name_idx = self.super_is_static_method
                        ? self.add_string_constant("__static_super__")
                        : self.add_string_constant("__super__");
                    ushort super_ctor_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_ctor_reg, super_name_idx));
                    if (self.super_is_static_method || self.super_is_home_object) {
                        super_proto_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROTO, (uint)super_proto_reg, (uint)super_ctor_reg, 0);
                        self.free_reg(super_ctor_reg);
                    } else {
                        uint proto_name_idx = self.add_string_constant("prototype");
                        ushort proto_key_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
                        super_proto_reg = self.alloc_reg();
                        self.emit_abc(Opcode.GETPROP, (uint)super_proto_reg, (uint)super_ctor_reg, (uint)proto_key_reg);
                        self.free_reg(proto_key_reg);
                        self.free_reg(super_ctor_reg);
                    }
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP_SUPER, (uint)result, (uint)super_proto_reg, (uint)super_key_reg);
                }

                self.last_was_member = true;
                self.last_member_obj_reg = super_proto_reg;
                self.last_member_prop_reg = super_key_reg;
                self.last_member_is_super = true;

                // For super method calls (super.m() / super[s]()), the this-binding
                // must be the current instance, not the prototype. Emit LDTHIS into a
                // fresh register and store it in call_prop_obj_reg so emit_call picks
                // it up. call_expr will free the register if no call follows.
                if (self.call_prop_obj_reg != MAX_REGISTERS) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                ushort this_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDTHIS, (uint)this_reg, 0, 0);
                self.call_prop_obj_reg = this_reg;

                return result;
            }

            return COMPILE_ERROR~;
        }

        case TokenType.TEMPLATE_HEAD:
        {
            // Template literal with substitutions: `text${expr}text${expr}text`
            Token head_tok = self.advance()!;
            if (head_tok.has_invalid_escape) {
                return COMPILE_ERROR~;
            }
            uint head_idx = self.add_string_constant(head_tok.str_value);
            ushort result_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)result_reg, head_idx));

            // Parse the expression inside ${...}. The closing `}` will be a
            // plain RBRACE token (B23 fix: the parser, not the lexer, owns
            // the substitution's brace boundary).
            ushort expr_reg = self.expression()!;

            // Consume the closing `}` and scan the next template part. This
            // produces a TEMPLATE_MIDDLE (more substitutions follow) or a
            // TEMPLATE_TAIL (template is complete).
            self.expect(TokenType.RBRACE)!;
            Token next_tok = self.lexer.scan_template_after_expr()!;

            // §13.2.8.1 SubstitutionEvaluation: each substitution value is
            // converted via ToString directly — unlike the `+` operator,
            // which goes through ToPrimitive(default) first. The two only
            // differ observably when Symbol.prototype[@@toPrimitive] has
            // been redefined/removed. Coerce here so the ADD below (both
            // operands already strings) is a plain concat, not a second
            // ToPrimitive pass.
            self.emit_abc(Opcode.TOSTR, (uint)expr_reg, 0, 0);

            // Concatenate: result = result + expr  (ADD handles string coercion)
            {
                ushort concat_reg = self.alloc_reg();
                self.emit_abc(Opcode.ADD, (uint)concat_reg, (uint)result_reg, (uint)expr_reg);
                self.free_reg(expr_reg);
                self.free_reg(result_reg);
                result_reg = concat_reg;
            }

            // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
            while (next_tok.type == TokenType.TEMPLATE_MIDDLE) {
                if (next_tok.has_invalid_escape) {
                    return COMPILE_ERROR~;
                }
                uint mid_idx = self.add_string_constant(next_tok.str_value);
                ushort mid_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)mid_reg, mid_idx));

                // Concatenate the middle text
                ushort concat_reg2 = self.alloc_reg();
                self.emit_abc(Opcode.ADD, (uint)concat_reg2, (uint)result_reg, (uint)mid_reg);
                self.free_reg(result_reg);
                self.free_reg(mid_reg);
                result_reg = concat_reg2;

                // Parse the next expression; consume its closing `}` and
                // scan the following template part.
                ushort next_expr_reg = self.expression()!;
                self.expect(TokenType.RBRACE)!;
                next_tok = self.lexer.scan_template_after_expr()!;

                // ToString the substitution value (see head-substitution comment above).
                self.emit_abc(Opcode.TOSTR, (uint)next_expr_reg, 0, 0);

                // Concatenate expression
                ushort concat_reg3 = self.alloc_reg();
                self.emit_abc(Opcode.ADD, (uint)concat_reg3, (uint)result_reg, (uint)next_expr_reg);
                self.free_reg(next_expr_reg);
                self.free_reg(result_reg);
                result_reg = concat_reg3;
            }

            if (next_tok.type != TokenType.TEMPLATE_TAIL) {
                // Expected TEMPLATE_MIDDLE or TEMPLATE_TAIL
                return COMPILE_ERROR~;
            }
            if (next_tok.has_invalid_escape) {
                return COMPILE_ERROR~;
            }

            uint tail_idx = self.add_string_constant(next_tok.str_value);
            ushort tail_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tail_reg, tail_idx));

            // Concatenate the tail text
            ushort concat_reg4 = self.alloc_reg();
            self.emit_abc(Opcode.ADD, (uint)concat_reg4, (uint)result_reg, (uint)tail_reg);
            self.free_reg(result_reg);
            self.free_reg(tail_reg);
            result_reg = concat_reg4;

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

        // `new MemberExpression` — e.g. `new Foo()`, `new new RegExp`.
        // Grammar: MemberExpression includes `new MemberExpression Arguments`,
        // so `new` can appear in any primary/member position and chains.
        case TokenType.NEW:
            return self.new_expr()!;

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
///
/// true/false/null/undefined are tokenized as IDENTIFIER tokens and handled
/// directly in `primary_expr`'s IDENTIFIER case, so this function is only
/// reached when `primary_expr`'s default case sees a token that cannot start
/// any expression (e.g. EOF, a stray operator with no operand). That is a
/// syntax error, not a valid empty expression — silently emitting `undefined`
/// here previously masked things like a lone `++`/`+` at end of input.
fn ushort? CompilerContext.literal_keyword(&self) {
    return self.fail("unexpected token in expression")~;
}

/// Parse object literal: { key: value, ... }
fn ushort? CompilerContext.object_literal(&self) {
    // An object literal is not an AnonymousFunctionDefinition — any pending
    // inferred name (e.g. from `var o = {...}`) does not apply here and
    // must not leak into a later, unrelated anonymous function expression
    // (ES2015 §12.15.4 NamedEvaluation only applies to the RHS itself).
    self.has_inferred_name = false;
    self.inferred_name_len = 0;
    self.expect(TokenType.LBRACE)!;

    // ES2015 §14.3.9: super.x in object literal methods resolves to
    // GetPrototypeOf(homeObject).x at call time.  Bind __super__ to the
    // literal object itself (the HomeObject); super.x emission then reads
    // the prototype dynamically via GETPROTO (see super_is_home_object),
    // so a later Object.setPrototypeOf on the literal is observed.
    bool saved_has_super = self.has_super_binding;
    bool saved_super_is_home = self.super_is_home_object;
    self.has_super_binding = true;
    self.super_is_home_object = true;

    ushort obj_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWOBJ, (uint)obj_reg, 0, 0);
    // The __super__ binding costs a register, so it is created lazily on the
    // first concise method / accessor — plain data literals skip it entirely
    // (large array-of-literal initialisers would otherwise exhaust registers).
    bool super_bound = false;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            if (self.check(TokenType.RBRACE)) {
                break;
            }

            // ES2015 §14.3: generator-method shorthand — `*m() { yield ... }`.
            // Save the generator + async flags; they are only overridden right
            // before compiling the method body below. Property keys, computed
            // keys, spread expressions, and `key: value` expressions are all
            // evaluated in the *enclosing* function's context (e.g. `...yield`
            // inside a generator body must still see is_generator = true), so
            // we must not clear the flags here.
            bool saved_is_generator = self.is_generator;
            bool saved_is_async = self.is_async;
            // ES2015 §12.2.6.1: `__proto__: value` sets the prototype, not an own property.
            bool is_proto_key = false;
            // Capture the byte offset of the property's very first token BEFORE
            // any async/star prefix is consumed, so Function.prototype.toString
            // source retention for method shorthand starts at `async`/`*`/the
            // key. match_async_method_prefix's pushback leaves the lexer's
            // token_start pointing past the key for identifier keys, so relying
            // on a later refresh would drop the method name (ES2019 §19.2.3.5).
            self.lexer.refresh_token_start();
            uint prop_src_start = self.lexer.token_start;
            // ES2017 §14.6: async-method shorthand — `{ async m() {} }`.
            // `async` is not a keyword; match_async_method_prefix consumes it
            // only when it is a modifier (followed on the same line by a
            // method-name token), so `{ async: 1 }`, `{ async }`, and
            // `{ async() {} }` all keep their existing meaning.
            bool is_async_method = self.match_async_method_prefix();
            bool is_generator_method = self.match(TokenType.STAR);
            // Async generator methods (`{ async *m() {} }`) are not supported.
            if (is_async_method && is_generator_method) {
                return self.fail("async generator methods are not supported")~;
            }

            // Parse property key
            ushort key_reg;
            uint shorthand_name_idx = 0;  // 0 = not a shorthand-eligible key
            char[] shorthand_name = {};   // identifier text, for local-var resolution
            bool is_shorthand_key = false;  // true iff the key came from a plain identifier
            bool is_computed_key = false;  // true iff the key came from `[expr]`
            // Source start for Function.prototype.toString retention. Captured
            // above (prop_src_start) at the property's first token, which is the
            // correct span origin for all method forms — `async`/`*` prefixes,
            // `get`/`set`, and identifier/string/number/computed keys alike.
            uint key_src_start = prop_src_start;

            TokenType key_tt = self.peek_type();
            if (key_tt == TokenType.IDENTIFIER || key_tt == TokenType.STRING
                || lexer::keyword_to_string(key_tt).len > 0) {
                Token key_tok = self.advance()!;
                // ES2015 §12.2.6.8: shorthand is only legal for a plain
                // IdentifierReference — string-literal keys and reserved
                // words used as keys must not be treated as shorthand.
                // `true` / `false` / `null` lex as plain IDENTIFIER tokens in
                // this lexer (resolved to literals by string comparison at
                // the primary-expression level) but are reserved words per
                // spec and cannot be used as an IdentifierReference.
                is_shorthand_key = key_tt == TokenType.IDENTIFIER
                    && !str_eq(key_tok.str_value, "true")
                    && !str_eq(key_tok.str_value, "false")
                    && !str_eq(key_tok.str_value, "null");

                // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
                // If key is "get" or "set" AND next token is a property key (not `:` or `(`)
                // Generator-method shorthand forbids the getter/setter shape — `*get` / `*set`
                // would otherwise be misparsed as a method shorthand that named `get`/`set`,
                // so we disable the detection entirely when a star was consumed.
                bool is_obj_getter = false;
                bool is_obj_setter = false;
                if (!is_generator_method && key_tt == TokenType.IDENTIFIER && !self.check(TokenType.COLON) && !self.check(TokenType.LPAREN)) {
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
                    // `async get x() {}` / `async set x(v) {}` are SyntaxErrors
                    // per ES2017 §14.6 — the async modifier only combines with
                    // plain method shorthand.
                    if (is_async_method) return COMPILE_ERROR~;
                    // Parse the actual property name
                    TokenType prop_tt = self.peek_type();
                    if (prop_tt == TokenType.LBRACKET) {
                        // Computed getter/setter key: `get [expr]() {}` / `set [expr](v) {}`
                        self.advance()!; // consume `[`
                        key_reg = self.assignment_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                        // ES2015 §12.2.6.7: ToPropertyKey happens as part of
                        // evaluating the computed key — coerce in place now
                        // (see the matching comment in the data-property
                        // computed-key branch below) so an abrupt completion
                        // (e.g. Object.create(null) with no toString/valueOf)
                        // throws here rather than being silently accepted.
                        self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
                    } else {
                        Token prop_tok;
                        if (prop_tt == TokenType.IDENTIFIER || prop_tt == TokenType.STRING
                            || lexer::keyword_to_string(prop_tt).len > 0) {
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

                        // ES2015 §14.3: getter/setter names are prefixed with
                        // "get " or "set " so `o = { get foo() {} }; o.foo.name === "get foo"`.
                        // Always overwrite the inherited inferred name (from var
                        // `o = ...`) — the property key + get/set prefix is the
                        // more specific source.
                        char[] prefix = is_obj_getter ? "get " : "set ";
                        usz prop_len = prop_tok.str_value.len;
                        if (prefix.len + prop_len < 128) {
                            self.has_inferred_name = true;
                            self.inferred_name_len = (ushort)(prefix.len + prop_len);
                            for (usz i = 0; i < prefix.len; i++) {
                                self.inferred_name_buf[i] = prefix[i];
                            }
                            for (usz i = 0; i < prop_len; i++) {
                                self.inferred_name_buf[prefix.len + i] = prop_tok.str_value[i];
                            }
                        }
                    }

                    // Compile the getter/setter function body — pass the
                    // source offset of the `get`/`set` keyword so the retained
                    // source span starts there (per ES2019 §19.2.3.5).
                    // Accessors are never generators or async; clear the flags
                    // so an accessor defined inside a generator/async body does
                    // not inherit the enclosing function's kind.
                    self.is_generator = false;
                    self.is_async = false;
                    if (!super_bound) {
                        // Give this object literal's `__super__` binding its own
                        // lexical environment record (PUSH_LEX) instead of
                        // re-declaring `let __super__` directly in the enclosing
                        // scope — otherwise a sibling object literal later in the
                        // same block clobbers the first literal's binding and
                        // corrupts already-created closures that captured it.
                        self.emit_simple(Opcode.PUSH_LEX);
                        ushort sup_reg = self.declare_var("__super__", LET);
                        uint sup_name_idx = self.add_string_constant("__super__");
                        self.emit_abc(Opcode.LDREG, (uint)sup_reg, (uint)obj_reg, 0);
                        self.emit_a_bc(Opcode.PUTLEX, (uint)sup_reg, sup_name_idx);
                        super_bound = true;
                    }
                    ushort accessor_reg = self.function_expr_body(key_src_start)!;
                    if (is_obj_getter) {
                        self.emit_abc(Opcode.INITGET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    } else {
                        self.emit_abc(Opcode.INITSET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    }
                    self.free_reg(accessor_reg);
                    self.free_reg(key_reg);
                    self.is_generator = saved_is_generator;
                    self.is_async = saved_is_async;

                    if (!self.match(TokenType.COMMA)) {
                        break;
                    }
                    continue;
                }

                // Regular property (not getter/setter)

                // ES2015 §12.2.6.1: `__proto__: value` is prototype-set syntax
                // when the key is a plain identifier or string (not computed, not shorthand).
                if (key_tok.str_value.len == 9
                    && key_tok.str_value[0] == '_' && key_tok.str_value[1] == '_'
                    && key_tok.str_value[2] == 'p' && key_tok.str_value[3] == 'r'
                    && key_tok.str_value[4] == 'o' && key_tok.str_value[5] == 't'
                    && key_tok.str_value[6] == 'o' && key_tok.str_value[7] == '_'
                    && key_tok.str_value[8] == '_'
                    && !is_generator_method && !is_async_method) {
                    is_proto_key = true;
                }

                uint key_idx = self.add_string_constant(key_tok.str_value);
                shorthand_name_idx = key_idx;  // shorthand `{ name }` = GETVAR this name
                shorthand_name = key_tok.str_value;
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));

                // ES2015 §14.3 / §14.1.20: method name inference. Always overwrite
                // the inherited inferred name from the enclosing assignment — the
                // property key is the more specific source for the function name.
                self.has_inferred_name = true;
                self.inferred_name_len = (ushort)key_tok.str_value.len;
                if (key_tok.str_value.len < 128) {
                    for (ushort i = 0; i < self.inferred_name_len; i++) {
                        self.inferred_name_buf[i] = key_tok.str_value[i];
                    }
                }
            } else if (key_tt == TokenType.NUMBER) {
                Token key_tok = self.advance()!;

                uint key_idx = self.add_number_constant(key_tok.num_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.LBRACKET) {
                // Computed property key — clear inferred name since the actual
                // key is computed at runtime (per ES2015 §14.3 the inferred
                // name is the empty string for computed keys).
                is_computed_key = true;
                self.has_inferred_name = false;
                self.inferred_name_len = 0;
                // For plain computed methods `[expr](){}`, update key_src_start to
                // the `[` so toString returns `[ expr ]() {}`.  For generator methods
                // `* [expr](){}` and async methods `async [expr](){}` the span must
                // start at `*`/`async`, so keep the prop_src_start already stored in
                // key_src_start and leave it unchanged (ES2019 §19.2.3.5).
                if (!is_generator_method && !is_async_method) {
                    self.lexer.refresh_token_start();
                    key_src_start = self.lexer.token_start;
                }
                self.advance()!;
                key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
                // ES2015 §12.2.6.7 ComputedPropertyName: ToPropertyKey happens
                // immediately as part of evaluating the key, before the
                // accessor/method body is instantiated or the value expression
                // is evaluated. Coerce in place now so a coercion side effect
                // (e.g. a `toString` that mutates a variable the value
                // expression reads) or a ToPropertyKey abrupt completion is
                // observed at the right point, rather than deferred to the
                // INITGET/INITSET/INITPROP opcode after the value has already
                // been evaluated.
                self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
            } else if (self.match(TokenType.ELLIPSIS)) {
                // Object spread: ...expr
                // `*...expr` is not legal — restore flags and reject.
                if (is_generator_method) return COMPILE_ERROR~;
                ushort spread_reg = self.assignment_expr()!;
                self.emit_abc(Opcode.OBJSPRD, (uint)obj_reg, 0, (uint)spread_reg);
                self.free_reg(spread_reg);
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;

                if (!self.match(TokenType.COMMA)) {
                    break;
                }
                continue;
            } else {
                // Restore flags on every iteration-end path so a stray STAR
                // (e.g. `*}`) does not leak the saved state forward.
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;
                return COMPILE_ERROR~;
            }

            // Check for method shorthand or data property
            if (self.check(TokenType.LPAREN)) {
                // Method shorthand: key() { ... } — name inferred from key (set above)
                // Set the generator/async flags to exactly this method's own
                // kind (assign, not set-on-true: a plain method defined inside
                // a generator/async body must NOT inherit the enclosing
                // function's flags) and restore the saved flags immediately
                // after so the next iteration starts clean.
                self.is_generator = is_generator_method;
                self.is_async = is_async_method;
                // Pass key_src_start so the retained source span starts at the
                // key token (or `*`, or first computed-key bracket).
                if (!super_bound) {
                    // See the getter/setter branch above: an isolated PUSH_LEX
                    // scope keeps this literal's `__super__` binding from being
                    // clobbered by a sibling object literal later in the block.
                    self.emit_simple(Opcode.PUSH_LEX);
                    ushort sup_reg = self.declare_var("__super__", LET);
                    uint sup_name_idx = self.add_string_constant("__super__");
                    self.emit_abc(Opcode.LDREG, (uint)sup_reg, (uint)obj_reg, 0);
                    self.emit_a_bc(Opcode.PUTLEX, (uint)sup_reg, sup_name_idx);
                    super_bound = true;
                }
                ushort method_reg = self.function_expr_body(key_src_start)!;
                // Method shorthand is always a MethodDefinition (§14.3.9): unlike
                // `key: value`, SetFunctionName is unconditional, not gated on
                // IsAnonymousFunctionDefinition. Computed keys need INITPROPN so
                // the empty compile-time name gets patched at object-creation
                // time; static keys already have the correct name baked in.
                Opcode method_init_op = is_computed_key ? Opcode.INITPROPN : Opcode.INITPROP;
                self.emit_abc(method_init_op, (uint)obj_reg, (uint)key_reg, (uint)method_reg);
                self.free_reg(method_reg);
                self.free_reg(key_reg);
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;
            } else if (is_shorthand_key && (self.check(TokenType.COMMA) || self.check(TokenType.RBRACE))) {
                // ES2015 §12.2.6.8: IdentifierReference shorthand property
                // `{ cause }` is equivalent to `{ cause: cause }` — the value
                // comes from the binding named by the key. Only legal when
                // the property key came from an IdentifierReference or
                // StringLiteral, never a numeric/computed key. `*a` shorthand
                // is not legal (must be a method), nor is `async a` (the
                // async modifier requires a method).
                if (is_generator_method || is_async_method) return COMPILE_ERROR~;
                // Read the binding into a register, then PUTPROP as usual.
                // Resolve as a local (parameter/let/const/var register) first —
                // matching plain IdentifierReference resolution in primary_expr
                // — and only fall back to a dynamic GETVAR-by-name lookup when
                // it isn't a local (global scope, or a name not locally bound).
                bool resolved_local = false;
                if (!self.is_global) {
                    if (try val_reg = self.resolve_var(shorthand_name)) {
                        self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                        resolved_local = true;
                    }
                }
                if (!resolved_local) {
                    ushort val_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)val_reg, shorthand_name_idx));
                    self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                    self.free_reg(val_reg);
                }
                self.free_reg(key_reg);
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;
            } else {
                // key: value — name inferred from key (set above)
                // `*a: 1` is not legal per ES2015 §14.3 — generator shorthand
                // must be a method (`*a() {}`). Same for `async a: 1`.
                if (is_generator_method || is_async_method) return COMPILE_ERROR~;
                self.expect(TokenType.COLON)!;
                if (is_proto_key) {
                    // `__proto__: fn` is a prototype-set, not a property
                    // definition — no NamedEvaluation (§12.2.6.8 step 5).
                    self.has_inferred_name = false;
                    self.inferred_name_len = 0;
                } else if (is_computed_key) {
                    // ES2015 §12.2.6.9 step 6: `IsAnonymousFunctionDefinition`
                    // is a static check on the value expression, independent of
                    // the (runtime-computed) key. Set has_inferred_name with an
                    // *empty* name so a following function/arrow/class/generator
                    // expression still consumes and clears the flag (leaving its
                    // compiled name empty, to be patched at runtime once the key
                    // is known — see INITPROPN/class_initaccessor_set_name).
                    // Anything that is NOT such an expression (identifier ref,
                    // comma expr, literal, ...) never touches the flag, so it
                    // stays set afterward — that's the signal used below to
                    // choose INITPROPN vs plain INITPROP.
                    self.has_inferred_name = true;
                    self.inferred_name_len = 0;
                }
                ushort val_reg = self.assignment_expr()!;
                bool computed_val_is_anon_fn_def = is_computed_key && !is_proto_key && !self.has_inferred_name;
                self.has_inferred_name = false;
                self.inferred_name_len = 0;
                if (is_proto_key) {
                    // ES2015 §12.2.6.1: `__proto__: value` sets the object's [[Prototype]].
                    // Only object values and null are valid; non-objects are silently ignored.
                    self.emit_abc(Opcode.SETPROTO, (uint)obj_reg, (uint)val_reg, 0);
                } else if (computed_val_is_anon_fn_def) {
                    self.emit_abc(Opcode.INITPROPN, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                } else {
                    self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                }
                // LIFO free order: val_reg was allocated after key_reg.
                self.free_reg(val_reg);
                self.free_reg(key_reg);
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RBRACE)!;
    if (super_bound) {
        // Close the isolated __super__ lexical scope opened above.
        self.emit_simple(Opcode.POP_LEX);
    }
    self.has_super_binding = saved_has_super;
    self.super_is_home_object = saved_super_is_home;
    return obj_reg;
}

/// Parse array literal: [ expr, expr, ... ]
fn ushort? CompilerContext.array_literal(&self) {
    // Not an AnonymousFunctionDefinition — clear any pending inferred name
    // so it doesn't leak into an unrelated later function expression.
    // See the matching comment in object_literal.
    self.has_inferred_name = false;
    self.inferred_name_len = 0;
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
                    // Dynamic index: store at current idx_reg, then increment.
                    // Use INITPROP (DefinePropertyOrThrow) not PUTPROP ([[Set]]) so
                    // a non-writable prototype index doesn't block literal initialisation.
                    self.emit_abc(Opcode.INITPROP, (uint)arr_reg, (uint)idx_reg, (uint)elem_reg);
                    ushort one = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    // Compile-time index — use INITPROP (DefinePropertyOrThrow).
                    ushort idx_const = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_const, (int)index));
                    self.emit_abc(Opcode.INITPROP, (uint)arr_reg, (uint)idx_const, (uint)elem_reg);
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
    // Per-iteration lexical environments are required for ALL let/const
    // bindings in for-of loops (ES2015 §14.7.5.6 CreatePerIterationEnvironment).
    // Each iteration must see its own binding so closures created in different
    // iterations capture distinct values.  Previously this was gated on
    // capture-analysis, but the spec mandates per-iter envs unconditionally
    // for lexical bindings (even without closures) to preserve the correct
    // scope chain for nested functions and direct eval.
    bool needs_per_iter_env = !is_bare && is_lexical;

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
    //
    // These registers are loaded fresh each iteration because some iterator
    // protocols (generators) overwrite the callee slot during the CALL via
    // re-dispatch.  Reloading here keeps for-of correct across iterations.
    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();

    // ES spec §14.7.5.6 ForIn/OfBodyEvaluation: V starts as undefined.
    // In eval mode, reset eval_acc_reg before the loop so a zero-iteration
    // for-of (empty iterable) returns undefined, not a stale prior value.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Loop start
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);
    self.loop_stack[self.loop_depth - 1].iter_close_reg = (int)method_reg;

    // Per-iteration env prologue: each iteration creates a fresh declarative env
    // so closures in the body capture a distinct binding (spec §14.7.5.6).
    // INITTZ marks the binding as TDZ in the fresh env before the value is
    // written by PUTLEX/PUTLEX_C below — this ensures the env is consistent
    // with block() semantics.
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
    }

    // Step 5: Load callee + this, then call .next() each iteration
    //   result = CALL callee, 0    (result = next.call(iterator))
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

    // Step 5.b: If Type(nextResult) is not Object, throw TypeError
    // (ES2022 §14.7.5.6 step 3.b).
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);

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

    // Free loop-iteration temps (reverse order — stack discipline)
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // ── IteratorClose-on-error guard (ES2022 §14.7.5.6 steps g.i–iii) ──
    // Wrap the assignment + body in TRY/CATCH so that any abrupt completion
    // (throw from the body, assignment error, etc.) calls IteratorClose
    // before propagating.  B=1: throw completion — suppress errors from
    // .return access/call (the original throw takes precedence).
    uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Step 8: Assign to loop variable (inside TRY so assignment errors
    // trigger IteratorClose).
    self.emit_abc(Opcode.LDREG, (uint)loop_var, (uint)val_reg, 0);

    if (is_bare) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)loop_var, name_idx);
    } else {
        self.emit_var_store(loop_var, name_idx, is_lexical, is_const);
    }


    // Step 9: Body
    // In eval mode, reset eval_acc_reg at the start of each iteration body.
    // This ensures break with an empty body leaves undefined, matching spec
    // §14.7.5.6 UpdateEmpty semantics (V only updates on non-empty completions).
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    self.statement()!;

    // Normal path: end the try region and jump over the catch block.
    self.emit_simple(Opcode.ENDTRY);
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // Catch block: called on any abrupt completion (throw, etc.).
    uint catch_target = self.code_count;
    ushort err_reg = self.alloc_reg();
    self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);

    // Unwind per-iter env if present, then call IteratorClose (throw variant).
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 1, 0);

    // Re-throw the original error.
    self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
    self.free_reg(err_reg);

    // Patch the jump to skip the catch block.
    self.patch_jump(jump_over);

    // Patch the TRY instruction: flags=1 (catch only), BC=offset to catch block.
    uint catch_off = catch_target - iter_try_addr;
    self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
    // Jump slot (NOP): finally_offset = 0.
    self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

    // Per-iteration env epilogue (normal path): pop this iteration's env before
    // the back-jump.  For continue: the continue statement's own POP_LEX
    // unwinds cur_lex_depth back to saved_lex_depth (the per-iter level is
    // included), so continue lands on the JUMP below rather than on this
    // POP_LEX (avoids a double-pop).
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }

    // Continue target points to the JUMP, so a continue from the body (which already
    // emitted its own POP_LEX back to saved_lex_depth) jumps to the back-edge directly.
    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;

    // Jump back to loop start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    // Exit path (done=true): pop the per-iter env pushed at loop_start,
    // then emit the exhaustion ITER_CLOSE before pop_loop so break-patch
    // targets land after this — break emits its own ITER_CLOSE.
    self.patch_jump(exit_jump);
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 0, 0);
    self.pop_loop();

    // Free loop-overhead registers
    self.free_reg(callee_this_reg);
    self.free_reg(callee_reg);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}
