module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::re_bindings;
import std::io;

// ============================================================================
// Expression parsing
// ============================================================================

/// Fail if the previous RHS expression was an ArrowFunction, ArrowFunction
/// is AssignmentExpression-level and must not appear as a binary operand
/// (`1 + () => 2`, `#x in () => {}`, ES §13.16, §13.15).
macro CompilerContext.check_no_arrow_rhs(&self) {
    if (self.last_was_arrow_expr) {
        self.last_was_arrow_expr = false;
        self.fail("arrow function in expression position not allowed");
    }
}

/// Parse a full expression (comma operator at lowest precedence), with the
/// grammar's `[+In]`: an `in` operator is allowed at every level.
///
/// This is the entry point every nested grouping uses — parentheses, brackets,
/// call arguments, template substitutions — and each of those re-fixes the
/// grammar's In parameter to `[+In]`, so clearing forbid_in here is what makes
/// `for ((a in b);;)` and `for (f(a in b);;)` legal inside a `[~In]` head.
/// The head itself enters through expression_no_in().
fn ushort? CompilerContext.expression(&self) {
    bool saved_forbid_in = self.forbid_in;
    self.forbid_in = false;
    defer self.forbid_in = saved_forbid_in;
    return self.expression_inner();
}

/// Parse a full expression as `Expression[~In]`: a top-level `in` operator is
/// a SyntaxError. Only a C-style for head uses this (§14.7.4).
fn ushort? CompilerContext.expression_no_in(&self) {
    self.forbid_in = true;
    defer self.forbid_in = false;
    return self.expression_inner();
}

fn ushort? CompilerContext.expression_inner(&self) {
    // Reset the arrow-returned marker so each operand of a comma list (and
    // each `(` grouping / conditional / assignment RHS) parses in isolation.
    self.last_was_arrow_expr = false;
    // Capture the caller's void-context signal. Only the FINAL comma operand
    // supplies the expression's value; every earlier operand is discarded by the
    // comma. assignment_expr consumes and clears self.void_ctx on each call, so
    // we re-arm it: non-final operands are always void; the final operand is void
    // only if the whole expression is (outer_void). We arm each operand's void
    // flag *after* confirming a comma follows the previous one, so the operand
    // just parsed is known non-final and the next arming reflects the correct
    // final/non-final split. The first operand consumes the caller's flag, which
    // is correct: in the no-comma case it equals outer_void; with a comma it is
    // discarded and voiding is safe.
    bool outer_void = self.void_ctx;
    ushort result = self.assignment_expr()!;

    // Handle comma operator: evaluate each, keep last
    // Comma discards References, clear call_prop_obj_reg after each operand,
    // including the rightmost one (comma always returns a value, not a Reference).
    // Per ES2015 §12.2.1.3 NamedEvaluation, only direct `= expr` assignments
    // receive inferred names, a comma-expression result does not. Clear the flag
    // so the rightmost operand of `(a, function(){})` never gets the outer name.
    while (self.match(TokenType.COMMA)) {
        self.free_reg(result);
        // Discard left operand's reference
        if (self.call_prop_obj_reg != REG_NONE) {
            self.free_reg(self.call_prop_obj_reg);
            self.call_prop_obj_reg = REG_NONE;
        }
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
        // The operand about to be parsed inherits outer_void; if another comma
        // follows (next loop iteration), it was actually non-final and its value
        // is discarded by free_reg at the top of that iteration, but its void
        // flag was already consumed. To keep correctness simple and avoid voiding
        // an operand whose value might still be consumed, only propagate the
        // caller's outer_void here: the final operand gets it (correct), and any
        // non-final operand that misses the optimization merely emits the longer
        // sequence (its result is freed anyway). Never void an operand whose
        // value could survive.
        self.void_ctx = outer_void;
        result = self.assignment_expr()!;
        // Discard rightmost operand's reference too
        if (self.call_prop_obj_reg != REG_NONE) {
            self.free_reg(self.call_prop_obj_reg);
            self.call_prop_obj_reg = REG_NONE;
        }
        // ES §13.16.1: an Expression built with `,` has AssignmentTargetType
        // ~invalid~, so `(a, b) = 1` is a SyntaxError even though the final
        // operand `b` is itself a valid target. Drop the markers it set.
        self.clear_ref_markers();
    }

    return result;
}

/// Save the raw text of a just-resolved identifier for later SetFunctionName
/// inference (assignment_expr reads this when the LHS is a simple
/// IdentifierReference). Truncates (clears) if the name doesn't fit.
fn void CompilerContext.save_lhs_ident_name(&self, char[] name) {
    // A freshly resolved identifier is a bare IdentifierReference until a
    // CoverParenthesizedExpression closes around it, so clear the marker here
    // rather than leaving a stale one from an earlier `(x)`.
    self.last_lhs_name_parenthesized = false;
    // An IdentifierReference is a valid SimpleAssignmentTarget, so it also
    // retires any ~invalid~ verdict left by a previously parsed operand.
    self.last_target_invalid = false;
    if (name.len < 128) {
        for (ushort i = 0; i < name.len; i++) self.last_lhs_name_buf[i] = name[i];
        self.last_lhs_name_len = (ushort)name.len;
    } else {
        self.last_lhs_name_len = 0;
    }
}

/// Bookkeeping for a resolved-by-name identifier that turned out to be
/// `arguments`. Two effects, both required at every site that reads an
/// identifier without going through `primary_expr`:
///
///  - ES2022 §15.7.1 forbids `arguments` anywhere in a class field
///    initializer, including under `typeof`.
///  - Inside a non-arrow function body the reference makes the function need
///    an arguments object, which the VM only builds when `uses_arguments` is
///    set at call entry. Missing this is silent: the name simply doesn't
///    resolve, so `typeof arguments` reads back `"undefined"`.
fn void? CompilerContext.note_arguments_reference(&self, char[] name) {
    if (!str_eq(name, "arguments")) return;
    if (self.forbid_arguments) {
        return self.fail("'arguments' is not allowed in class field initializer")~;
    }
    if (!self.is_global) self.uses_arguments = true;
}

/// Parse an assignment expression.
///
/// Thin wrapper over assignment_expr_inner that stamps the AssignmentTargetType
/// verdict on the way out. It has to happen here, after the inner parse has
/// fully returned: the verdict cannot be set at the point the assignment
/// operator is consumed, because parsing the RHS resolves identifiers, and
/// every resolved identifier clears the flag (an IdentifierReference is a valid
/// target). `x = y` would set the verdict and then have `y` immediately wipe it.
fn ushort? CompilerContext.assignment_expr(&self) {
    bool saw_assign_op = false;
    ushort r = self.assignment_expr_inner(&saw_assign_op)!;
    if (saw_assign_op) {
        // ES §13.15.1: an AssignmentExpression has AssignmentTargetType
        // ~invalid~, so `(x = y) = 1` and `(x ??= y)++` are early SyntaxErrors.
        // Only this verdict is set; the reference markers keep carrying the
        // register-aliasing hint the enclosing operator's copy-to-temp guard
        // needs (b0fdc49c), which is why the two are separate flags.
        self.last_target_invalid = true;
    }
    return r;
}

fn ushort? CompilerContext.assignment_expr_inner(&self, bool* saw_assign_op) {
    // Reset so a parenthesized arrow LHS doesn't survive past the destructure check.
    self.last_was_arrow_expr = false;
    // Consume the caller's void-context signal exactly once, into a local, and
    // clear the field so it can NOT leak into the recursive RHS parse (the RHS
    // value is always consumed by the store). Only the outermost assignment in
    // a `void`-flagged statement/clause discards its result.
    bool void_ctx = self.void_ctx;
    self.void_ctx = false;

    // We are at the head of an AssignmentExpression, the one position where a
    // YieldExpression may start. conditional_expr and everything below clear
    // this again before descending, so `!yield` / `1 + yield` still fail.
    self.yield_ok_here = true;

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

        // Skip past the pattern (match brackets/braces at any depth),
        // template-aware (see TemplateScan) so a `}` closing a `${` is not
        // counted as pattern nesting: miscounting it consumes a real `}` to
        // compensate and runs the scan far past the pattern, resuming the
        // re-lex from a position inside a later string or template.
        self.advance()!; // consume '[' or '{'
        uint depth = 1;
        TemplateScan tscan;
        while (depth > 0) {
            Token? next_opt = self.lexer.next_token();
            if (try next = next_opt) {
                if (next.type == TokenType.LBRACE) {
                    tscan.on_lbrace();
                    depth++;
                } else if (next.type == TokenType.LBRACKET) {
                    depth++;
                } else if (next.type == TokenType.TEMPLATE_HEAD) {
                    tscan.on_template_head();
                } else if (next.type == TokenType.RBRACE) {
                    TemplateBrace tb = tscan.classify_rbrace(self.lexer);
                    if (tb == TemplateBrace.LEX_ERROR) break;
                    if (tb == TemplateBrace.BLOCK) depth--;
                } else if (next.type == TokenType.RBRACKET) {
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
            // Destructuring assignment, parse pattern and RHS
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
        // Not destructuring assignment, fall through to normal expression parsing
    }

    // Parse LHS with lhs_mode enabled, member_expr saves (obj, key) without GETPROP
    self.lhs_mode = true;
    self.last_was_member = false;
    // Clear before the operand parse so the flag describes THIS operand, not
    // some earlier assignment (`a = 1, b = 2` must not see `a = 1`'s).
    // conditional_expr sets it again only if the operand it returns really was
    // an assignment (through a nested assignment_expr, e.g. inside parens).
    self.last_was_assignment = false;
    ushort left = self.conditional_expr()!;
    self.lhs_mode = false;

    TokenType tt2 = self.peek_type();

    // If LHS was a member expression but next token is NOT an assignment,
    // free the saved obj/key registers (GETPROP was already emitted).
    // Skip this cleanup when inside parens or in delete mode: the inner
    // member reference isn't actually a candidate for assignment, the
    // enclosing grouping/del expression still needs the obj/prop tracks
    // for patch-into-DELPROP (delete) or for the outer assignment check
    // (CoverParenthesizedExpression is never a valid assignment target
    // in strict mode, so the grouping here can't be an assignment LHS).
    if (!self.inside_parens && !self.del_mode
        && self.last_was_member && tt2 != TokenType.ASSIGN
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

    // §13.15.1: an AssignmentExpression has AssignmentTargetType ~invalid~,
    // so it may not itself be assigned to. Read the LHS's flag before
    // consuming the operator, then re-arm it for this assignment's own result.
    bool lhs_was_assignment = self.last_was_assignment;
    self.last_was_assignment = true;

    // Consume the assignment operator
    self.advance()!;

    if (self.last_was_optional_chain) {
        self.record_error("Invalid left-hand side in assignment");
        return COMPILE_ERROR~;
    }

    // ES2024 §13.15.1: "It is a Syntax Error if the AssignmentTargetType of
    // LeftHandSideExpression is invalid." A CallExpression target such as
    // `f() = 1` reaches here with none of the reference markers set, so it is
    // rejected at parse time, matching QuickJS. V8/node instead parse it and
    // throw a ReferenceError at runtime; that leniency is NOT copied, and the
    // reason is worth recording because — unlike the other node divergences —
    // the spec does sanction a deferral here.
    //
    // AssignmentTargetType (ES2025 §8.6.4) returns simple, web-compat or
    // invalid, and the CallExpression clause is a Normative Optional:
    //
    //     CallExpression : CoverCallExpressionAndAsyncArrowHead
    //     CallExpression : CallExpression Arguments
    //       1. If the host is a web browser or otherwise supports Runtime
    //          Errors for Function Call Assignment Targets, and
    //          IsStrict(this CallExpression) is false, then return web-compat.
    //       2. Return invalid.
    //
    // Annex B.3.9 "Runtime Errors for Function Call Assignment Targets": "When
    // a function call (13.3.6) is used as an assignment target in non-strict
    // code, instead of producing an early error, a ReferenceError exception is
    // thrown during evaluation of the assignment."
    //
    // The allowance is real but unreachable here: it is gated on
    // IsStrict(this CallExpression) being false, and this engine is
    // strict-only, so IsStrict is always true and step 1 never fires. Step 2
    // returns invalid and §13.15.1's early error applies. The early
    // SyntaxError is therefore the only spec-conforming outcome for this
    // engine, not merely the stricter of two permitted readings.
    //
    // The early errors quoted above key off invalid specifically, so web-compat
    // suppresses them; the corresponding runtime clauses (e.g. §13.4.2.1 step 2)
    // throw the ReferenceError instead. B.3.9's Note further restricts the
    // allowance to `=` and AssignmentOperator: it never applies to `&&=`, `||=`
    // or `??=`, whose §13.15.1 clause tests "is not simple" rather than
    // "is invalid" and so rejects web-compat too.
    //
    // test262 agrees and covers this directly: all ten
    // language/expressions/assignmenttargettype/*callexpression* tests that
    // cite the web-compat clause expect `phase: parse, type: SyntaxError`, and
    // every one whose operator is deferrable is flagged onlyStrict. The two
    // logical-assignment cases carry no strictness flag, exactly as B.3.9's
    // Note requires. All ten pass. node fits the same shape — it defers for
    // `=`, `+=` and `++` but keeps a SyntaxError for `&&=`/`??=` — so it is
    // implementing B.3.9; it just also applies it to genuinely strict code
    // (a `.mjs` module still yields ReferenceError), which B.3.9 does not
    // permit.
    if (self.last_target_invalid || (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var)) {
        self.record_error("Invalid left-hand side in assignment");
        return COMPILE_ERROR~;
    }

    // ES5 §11.13.1 strict mode: assigning to 'eval' or 'arguments' is a
    // SyntaxError. Only fires for a bare identifier target, member
    // expressions never reach here with last_lhs_name_len set
    // (save_lhs_ident_name is called only from identifier resolution).
    // `await` is reserved in this position only when the [Await] grammar
    // parameter says so, i.e. inside an async function/arrow/method, a
    // module, or a class static block; outside those scopes `await = 1` is a
    // legal simple assignment. `yield` is reserved unconditionally (strict-
    // only engine), which is the helper's default.
    if (!self.last_was_member && self.last_lhs_name_len > 0
        && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len],
                              self.is_async || self.is_module || self.forbid_await)) {
        return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
    }

    // Save LHS info (will be overwritten by RHS evaluation)
    bool lhs_was_getvar = self.last_was_getvar;
    bool lhs_was_getglobal = self.last_was_getvar && self.last_was_getglobal;
    bool lhs_was_getglobal_prim = lhs_was_getglobal && self.last_was_getglobal_prim;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;
    // The opcode that writes back a bare-identifier LHS: PUTGLOBAL_PRIM for a
    // proven primitive-only global (guard-free), PUTGLOBAL at true global scope
    // (mirrors GETGLOBAL), else PUTVAR_ASSIGN.
    Opcode ident_store_op = lhs_was_getglobal_prim ? Opcode.PUTGLOBAL_PRIM
        : (lhs_was_getglobal ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN);
    ushort lhs_ref_reg = REG_NONE;
    bool lhs_was_member = self.last_was_member;
    ushort lhs_member_obj = self.last_member_obj_reg;
    ushort lhs_member_prop = self.last_member_prop_reg;
    bool lhs_member_obj_is_local = self.last_member_obj_is_local;
    bool lhs_was_local_var = self.last_was_local_var;
    // An assignment operator has been consumed and the LHS markers are
    // captured, so this is the one point every store form converges. Report it
    // to the wrapper, which stamps the ~invalid~ verdict after the RHS parse
    // (which would otherwise clear it) has finished. Covers all forms alike:
    // local register, global, member, compound and logical.
    *saw_assign_op = true;
    // super.x stores go through PUTPROP_SUPER (receiver = this, §13.15.2).
    Opcode member_store_op = self.last_member_is_super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP;
    // Save the LHS identifier text for SetFunctionName (below) before it
    // gets clobbered by RHS parsing.
    char[128] lhs_ident_name_buf = self.last_lhs_name_buf;
    // A parenthesized LHS keeps its AssignmentTargetType (so the eval /
    // arguments check above still ran) but is not an IsIdentifierRef, so it
    // must not drive NamedEvaluation: `(fn) = function(){}` leaves the
    // function anonymous.
    ushort lhs_ident_name_len = self.last_lhs_name_parenthesized
        ? 0 : self.last_lhs_name_len;

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
                if (lhs_was_getvar && !lhs_was_getglobal && self.code_count > 0
                    && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    uint getvar_reg = self.code[self.code_count - 1].a;
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, getvar_reg, name_idx);
                } else if (lhs_was_getglobal && self.code_count > 0
                    && (self.code[self.code_count - 1].op == Opcode.GETGLOBAL
                        || self.code[self.code_count - 1].op == Opcode.GETGLOBAL_PRIM)) {
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    uint getglobal_reg = self.code[self.code_count - 1].a;
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_GLOBAL, getglobal_reg, name_idx);
                } else {
                    self.emit_abc(Opcode.DEC, (uint)left, 0, 0);
                    if (lhs_was_getvar) {
                        // The store clears its source register, so preserve the
                        // decremented value in a temp for the expression result
                        // (matters for eval completion value / chained use).
                        ushort tmp = self.alloc_reg();
                        self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                        self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                        self.free_reg(left);
                        left = tmp;
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
            uint lor_const_ni = 0;
            if (!lhs_was_member && lhs_was_getvar) {
                lor_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)lor_res, (uint)left, 0);
            } else if (!lhs_was_member) {
                lor_const_ni = self.find_const_name_idx(left);
            }
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)lor_res);
            ushort right = self.assignment_expr()!;
            // The RHS parse cleared last_was_assignment (it describes the
            // operand it just read); re-arm it, this expression IS one.
            self.last_was_assignment = true;
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
                    self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                } else if (lor_const_ni != 0xFFFFFFFFu) {
                    // Register-cached CONST target: route through PUTVAR_ASSIGN
                    // so the env const check fires (plan 062 group H).
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)lor_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, lor_const_ni);
                }
                la_result = lor_res;
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_logical_and_assign) {
            // x &&= expr: skip RHS if left is falsy.
            ushort land_res = left;
            uint land_const_ni = 0;
            if (!lhs_was_member && lhs_was_getvar) {
                land_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)land_res, (uint)left, 0);
            } else if (!lhs_was_member) {
                land_const_ni = self.find_const_name_idx(left);
            }
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)land_res);
            ushort right = self.assignment_expr()!;
            // The RHS parse cleared last_was_assignment (it describes the
            // operand it just read); re-arm it, this expression IS one.
            self.last_was_assignment = true;
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
                    self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                } else if (land_const_ni != 0xFFFFFFFFu) {
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)land_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, land_const_ni);
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
            uint nc_const_ni = 0;
            if (!lhs_was_member && lhs_was_getvar) {
                nc_res = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)nc_res, (uint)left, 0);
            } else if (!lhs_was_member) {
                nc_const_ni = self.find_const_name_idx(left);
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
            // Not nullish, skip RHS
            self.free_reg(cmp_reg);
            uint skip_jump = self.emit_jump(Opcode.JUMP);
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);
            // Nullish, evaluate RHS and assign
            ushort right = self.assignment_expr()!;
            // The RHS parse cleared last_was_assignment (it describes the
            // operand it just read); re-arm it, this expression IS one.
            self.last_was_assignment = true;
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
                    self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                } else if (nc_const_ni != 0xFFFFFFFFu) {
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)nc_res, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, nc_const_ni);
                }
                la_result = nc_res;
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
    }

    // Plain member assignment must not evaluate the LHS property read,
    // only the object and key are evaluated (§13.15.2).  Drop the GETPROP
    // (or GETPROP_CACHE / GETPROP_SUPER) emitted while parsing the target so
    // getters / proxy [[Get]] traps don't run as a side effect, and so any
    // GETPROP_CACHE key-coercion writeback doesn't run before RHS either
    // (`base[prop] = expr()` must ToPropertyKey(prop) AFTER expr()). For
    // super targets, this also defers the HomeObject null-prototype
    // TypeError: per spec MakeSuperPropertyReference computes [[Base]]
    // eagerly (never throws, GetSuperBase just returns null), but the
    // actual ToObject(base) check happens inside PutValue, AFTER the RHS has
    // been evaluated (§6.2.5.6). Stripping the eager read here means
    // PUTPROP_SUPER's own null-base check performs that throw at the
    // correct point, after RHS runs. Compound/logical assignments keep the
    // read (they genuinely need the old value, and rely on GETPROP_CACHE's
    // writeback for the follow-up PUTPROP to be idempotent).
    if (is_assign && lhs_was_member && self.code_count > 0) {
        Instruction lhs_last = self.code[self.code_count - 1];
        if ((lhs_last.op == Opcode.GETPROP || lhs_last.op == Opcode.GETPROP_CACHE
            || lhs_last.op == Opcode.GETPROP_PRIVATE)
            && (ushort)lhs_last.a == left
            && (ushort)lhs_last.b == lhs_member_obj && (ushort)lhs_last.c == lhs_member_prop) {
            // Strip the read for plain assignment so a getter (private
            // accessor) isn't invoked as a side effect of LHS evaluation.
            // PrivateFieldSet reads nothing, only CHK_BRAND + [[Set]] runs.
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
                        self.call_prop_obj_reg = REG_NONE;
                    }
                    self.code_count -= 2;
                }
            } else if (lhs_last.op == Opcode.GETPROP_SUPER && (ushort)lhs_last.a == left
                && (ushort)lhs_last.b == lhs_member_obj && (ushort)lhs_last.c == lhs_member_prop) {
                self.code_count--;
            }
        }
    }

    // For plain assignment to an identifier, preserve whether the identifier
    // resolved before evaluating the RHS. Per ES2022 §13.15.2 step 1,
    // evaluating the LHS IdentifierReference produces a Reference, not a
    // value. Non-strict code keeps the old value-discarding path.
    if (is_assign && lhs_was_getvar && self.code_count > 0) {
        Instruction lhs_last = self.code[self.code_count - 1];
        if ((lhs_last.op == Opcode.GETVAR || lhs_last.op == Opcode.GETGLOBAL
             || lhs_last.op == Opcode.GETGLOBAL_PRIM)
            && (ushort)lhs_last.a == left) {
            // A strict plain assignment must, per PutValue, capture LHS
            // resolvability BEFORE the RHS runs, hence the RESOLVEVAR probe
            // and IF_TRUE/THROW_REF guard emitted below. But when the LHS is a
            // GETGLOBAL naming a global THIS unit hoisted (CHKGLOBALVAR /
            // CHKGLOBALFUNC ran for it), resolvability is statically TRUE, so
            // the guard is provably dead: strip the read (its value is
            // discarded) and leave lhs_ref_reg unset. Undeclared globals keep
            // the guard, e.g. `undeclared = (this.undeclared = 5)` must still
            // throw even though the RHS would create the global. A GETGLOBAL_PRIM
            // LHS is by construction a declared primitive-only global, so it is
            // statically resolvable too, so strip its dead read.
            if (lhs_last.op == Opcode.GETGLOBAL_PRIM
                || (lhs_last.op == Opcode.GETGLOBAL
                    && self.is_declared_global(lhs_getvar_name_idx))
                || (lhs_last.op == Opcode.GETVAR
                    && lhs_ident_name_len > 0
                    && self.is_statically_resolvable_local(
                           lhs_ident_name_buf[:lhs_ident_name_len]))) {
                self.code_count--;
            } else {
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.RESOLVEVAR, (uint)left, lhs_getvar_name_idx);
                lhs_ref_reg = left;
            }
        }
    }

    // ES2015 §12.15.4 AssignmentExpression: `x = anonymousFn`, when the LHS
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
    } else {
        // This assignment supplies no inferred name, so clear any left by an
        // EARLIER one. The name is consumed lazily by whichever anonymous
        // function/class/arrow the RHS turns out to contain, and a
        // non-contributing assignment in between would otherwise donate its
        // predecessor's name: `(w = 2) * (w = 3); (fn) = function(){}` named
        // the function "w".
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // Materialize the compound target's OLD VALUE before the RHS runs.
    // `g op= rhs` is: resolve the Reference for g, GetValue(g) -> old,
    // evaluate rhs, then apply op(old, rhs), so the read of g happens
    // *first*. The compound path below applies `op` to `left` after the RHS
    // has been compiled, and when `left` is a plain local's home register an
    // assignment to that same variable inside the RHS overwrites the old
    // value in place:
    //
    //     function f(){ var g = 5; g += (g = 2); return g; }  // 4, node says 7
    //     function h(){ var g = 5; g -= (g = 2); return g; }  // 0, node says 3
    //
    // computing 2 + 2 instead of 5 + 2. Copying the old value to a temp here
    // restores the specified order. Gated on the same conservative lookahead
    // as binary_expr's left-operand guard, so a RHS that cannot write a
    // register leaves the emitted code unchanged.
    //
    // Only reached for `op=`; the logical forms (&&=, ||=, ??=) return above
    // because they must short-circuit and not evaluate the RHS at all.
    ushort compound_old = left;
    bool compound_old_copied = false;
    if (is_compound && !lhs_was_member && !lhs_was_getvar && lhs_was_local_var
        && self.rhs_may_write_registers()) {
        compound_old = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)compound_old, (uint)left, 0);
        compound_old_copied = true;
    }

    // Compile right-hand side
    ushort right = self.assignment_expr()!;
    // The RHS parse cleared last_was_assignment (it describes the operand it
    // just read); re-arm it, this expression IS one.
    self.last_was_assignment = true;
    // A bare identifier RHS that resolved to a live local variable's own
    // register (not a temp) must never be freed here, free_reg is LIFO and
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
            // The base can be a live let/const home register: member_expr
            // uses the binding's slot directly as the operand. Nothing sits
            // above it here (the compound and logical paths keep a result
            // register live across these frees), so the pop would hand the
            // slot to the alloc_reg below, whose LDREG then overwrites the
            // variable. Local homes are released at scope exit, not here.
            if (!lhs_member_obj_is_local) {
                self.free_reg(lhs_member_obj);
            }
            // The assignment expression evaluates to the assigned value. When
            // `right` is a live local's own register we must not return it (a
            // later free would alias it); when it is a temp we must copy the
            // value into a freshly allocated result BEFORE freeing `right`,
            // otherwise the returned register is dangling (freed, reusable by
            // the next alloc) and reads back as whatever last landed there.
            // This surfaced via `import(o.p = x)`: the specifier read undefined.
            ushort assign_result = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)assign_result, (uint)right, 0);
            if (!right_is_local) { self.free_reg(right); }
            left = assign_result;
        } else {
            if (lhs_ref_reg != REG_NONE) {
                self.emit_a_bc(Opcode.THROW_UNRESOLVED, (uint)lhs_ref_reg, lhs_getvar_name_idx);
            }
            if (void_ctx && lhs_was_getvar) {
                // Result is discarded: skip both the LHS-register copy and the
                // result-preservation copy. PUTVAR/PUTGLOBAL clears its source
                // register, which is harmless here since nothing else reads it,
                // UNLESS `right` is a live local variable's home register, which
                // must never be clobbered. In that case copy into `left` (a temp)
                // and store from there (one move); otherwise store straight from
                // `right` and free it (zero moves).
                //
                // We do NOT free the returned register here, the caller's
                // expression/expression_statement free logic owns it. `left` was
                // allocated before `right`, so `right` is the top of the register
                // stack; returning `right` lets the caller's LIFO free_reg
                // actually reclaim it.
                if (right_is_local) {
                    // Store directly from the variable's home register; PUTVAR
                    // clears its source, so route through `left` (a temp) to
                    // avoid clobbering the live local. `left` is below `right`
                    // on the stack, so free `right` first to keep LIFO order,
                    // then return `left`.
                    if (left != right) {
                        self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                        self.free_reg(right);
                    }
                    self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                    return left;
                }
                // `right` is a temp: store straight from it, no moves.
                if (left != right) { self.free_reg(left); }
                self.emit_a_bc(ident_store_op, (uint)right, lhs_getvar_name_idx);
                return right;
            }
            if (void_ctx) {
                // Register-cached CONST target in a discarded context (e.g.
                // `for (const v of arr) { v = 2; }` body, plan 062 group H).
                // Mirror the lhs_was_getvar branch above so the env-based
                // PUTVAR_ASSIGN fires the const check.
                uint const_ni = self.find_const_name_idx(left);
                if (const_ni != 0xFFFFFFFFu) {
                    if (left != right) {
                        self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                        self.free_reg(right);
                    }
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, const_ni);
                    return left;
                }
            }
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
                self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
                self.free_reg(left);
                left = tmp;
            } else {
                uint const_ni = self.find_const_name_idx(left);
                if (const_ni != 0xFFFFFFFFu) {
                    // Register-cached CONST target (e.g. `for (const v of arr)
                    // { v = 2; }` after the for-of head, plan 062 group H). The
                    // LDREG above wrote the new value into the register, but a
                    // const violation must still throw TypeError. Force PUTVAR_ASSIGN
                    // through the env so the runtime's non-writable flag fires.
                    ushort tmp = self.alloc_reg();
                    self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, const_ni);
                    self.free_reg(left);
                    left = tmp;
                } else {
                    // `left` IS the target local's home register, and it is
                    // what this assignment expression evaluates to. Mark it so
                    // an enclosing operator (`(u = 45) > 0`, `(u = 45) + 1`)
                    // copies it to a temp instead of using the variable's own
                    // slot as the result destination and clobbering it.
                    self.last_was_local_var = true;
                    self.last_local_var_reg = left;
                    return left;
                }
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
        // Read the old value from the temp saved before the RHS ran when the
        // RHS may have overwritten the variable's home register; otherwise
        // `compound_old == left` and this is the original in-place form.
        self.emit_abc(compound_op, (uint)result_reg, (uint)compound_old, (uint)right);
        if (compound_old_copied) { self.free_reg(compound_old); }
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
            self.emit_a_bc(ident_store_op, (uint)left, lhs_getvar_name_idx);
            self.free_reg(left);
            left = tmp;
        } else {
            uint const_ni = self.find_const_name_idx(left);
            if (const_ni != 0xFFFFFFFFu) {
                // Register-cached CONST target. The compound op wrote the new
                // value into `left`; route a PUTVAR_ASSIGN through the env so a
                // const violation throws TypeError (plan 062 group H).
                ushort tmp = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
                self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)left, const_ni);
                self.free_reg(left);
                left = tmp;
            } else {
                // As in the simple-assignment path above: `left` IS the
                // target local's home register and doubles as this
                // expression's value, so mark it for the enclosing
                // operator's copy-to-temp guard (`(n *= 0.3) > 0`).
                self.last_was_local_var = true;
                self.last_local_var_reg = left;
                return left;
            }
        }
        return left;
    }

    return left;
}

/// Parse a conditional (ternary) expression: expr ? expr : expr
fn ushort? CompilerContext.conditional_expr(&self) {
    // Reset so an arrow that came in as the condition doesn't trip the binary
    // operator check on the operator that follows the conditional.
    self.last_was_arrow_expr = false;
    // binary_expr consumes forbid_in (see the no_in capture there), but a
    // ConditionalExpression's own In parameter still governs its false
    // branch: `ConditionalExpression[?In] : ShortCircuitExpression[?In] ?
    // AssignmentExpression[+In] : AssignmentExpression[?In]`. Hold it across
    // the condition so the branches below see the enclosing value.
    bool cond_forbid_in = self.forbid_in;
    ushort result = self.binary_expr(PREC_NULLISH)!;

    if (self.match(TokenType.QUESTION)) {
        // Allocate result register
        ushort result_reg = self.alloc_reg();

        // Jump to else branch if condition is false
        uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)result);
        self.free_reg(result);

        // True branch. The grammar fixes this operand to
        // `AssignmentExpression[+In]` regardless of the enclosing In
        // parameter, so an `in` here is legal even inside a for head.
        self.forbid_in = false;
        ushort true_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)true_val, 0);
        self.free_reg(true_val);

        self.expect(TokenType.COLON)!;

        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // False branch: `AssignmentExpression[?In]`, so it inherits.
        self.forbid_in = cond_forbid_in;
        ushort false_val = self.assignment_expr()!;
        self.forbid_in = false;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)false_val, 0);
        self.free_reg(false_val);

        self.patch_jump(end_jump);

        // ES §13.14.1: a ConditionalExpression has AssignmentTargetType
        // ~invalid~ — `(a ? b : c) = 1` is a SyntaxError even though the false
        // branch just parsed may itself have been a plain identifier.
        self.clear_ref_markers();
        return result_reg;
    }

    return result;
}

/// Parse binary expressions using a Pratt parser with precedence climbing.
fn ushort? CompilerContext.binary_expr(&self, int min_prec) {
    self.last_was_local_var = false;
    // Clear any arrow marker from an enclosing binary_expr so the initial
    // LHS capture below is authoritative.
    self.last_was_arrow_expr = false;

    // A YieldExpression may only appear where an AssignmentExpression is
    // expected. binary_expr's operands are Unary/Shift/etc, so consume the
    // permission left by assignment_expr: the leftmost operand keeps it (a
    // bare `yield` reaching here IS still at the head of the
    // AssignmentExpression), but every operand parsed after an operator sees
    // it cleared, which is what rejects `1 + yield` and `a || yield`.
    bool yield_ok = self.yield_ok_here;
    self.yield_ok_here = false;

    // `[~In]` reaches exactly one decision: whether this invocation's operator
    // loop may consume an `in`. Every operand is parsed with the flag cleared,
    // so it can never leak into a nested construct — a parenthesized
    // subexpression, a call argument, an array element, a template
    // substitution — all of which are `[+In]` by grammar no matter which entry
    // point they use. This is the same consume-on-entry discipline as
    // yield_ok_here above, and it is what keeps `for (f(a in b);;)` legal
    // while `for (a in b;;)` is not.
    bool no_in = self.forbid_in;
    self.forbid_in = false;
    // A YieldExpression propagates `?In` to its operand instead of forcing
    // `+In`, and it is reached from primary_expr, below the clear above. Park
    // the consumed value where the yield case can find it; it travels with
    // yield_ok_here, since that marks the only position a yield can appear.
    self.yield_forbid_in = no_in && yield_ok;

    // ES2022 class-fields-private-in: `[+In] PrivateIdentifier in ShiftExpression`.
    // The grammar gives the PrivateIdentifier as a standalone LHS of the `in`
    // operator, `#x` is not a value expression by itself. If the next token is
    // HASH_IDENT immediately followed by `in`, consume both and emit the
    // HAS_BRAND probe; the result then feeds the normal Pratt loop so lower-
    // precedence continuations (`#x in o && y`, `#x in o === b`) still parse.
    // The `#x in o` production is itself guarded by `[+In]`, so it is
    // unavailable in a for head for the same reason a plain `in` is.
    ushort left;
    if (min_prec <= get_binary_precedence(TokenType.IN) && !no_in
            && self.peek_type() == TokenType.HASH_IDENT) {
        Token hash_tok = self.advance()!;
        if (self.peek_type() == TokenType.IN) {
            self.advance()!;  // consume 'in'
            // Resolve #name to its slot entry (a SyntaxError if the private
            // name has no declaration in any enclosing class, matches
            // AllPrivateIdentifiersValid early-error semantics).
            PrivateNameEntry* entry = self.resolve_private_name(hash_tok.str_value)!;
            // The brand binding lives in this context's pool.
            uint brand_bind_idx = self.add_string_constant(entry.brand_slot_name);
            ushort brand_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.GETVAR, (uint)brand_reg, brand_bind_idx);

            // Parse RHS with precedence above IN so relational ops don't
            // chain into the probe's object operand.
            ushort rhs = self.binary_expr(get_binary_precedence(TokenType.IN) + 1)!;
            self.check_no_arrow_rhs();

            // HAS_BRAND: A=dst, B=object, C=brand register. 8-bit register
            // fields, same layout and register-budget constraint as the
            // existing CHK_BRAND.
            ushort dst = self.alloc_reg();
            self.emit_abc(Opcode.HAS_BRAND, (uint)dst, (uint)rhs, (uint)brand_reg);
            self.free_reg(brand_reg);
            self.free_reg(rhs);
            left = dst;
        } else {
            // Not followed by `in`, `#x` alone is not a valid expression.
            // Push the HASH_IDENT back so unary_expr surfaces a real error.
            self.lexer.pushback(hash_tok);
            self.yield_ok_here = yield_ok;
            left = self.unary_expr()!;
        }
    } else {
        // The leftmost operand is still at the head of the enclosing
        // AssignmentExpression, so `yield + 1` and `yield, 1` stay legal.
        self.yield_ok_here = yield_ok;
        left = self.unary_expr()!;
    }
    self.yield_ok_here = false;
    // Capture immediately: parsing any right operand below re-runs unary_expr
    // and overwrites the flag with that operand's shape.
    bool left_was_unary_op = self.last_was_unary_op;
    self.last_was_unary_op = false;
    bool left_was_newline_yield = self.last_was_newline_yield;
    self.last_was_newline_yield = false;
    bool left_is_local = self.last_was_local_var;
    // Do NOT clear self.last_was_arrow_expr here, the recursive RHS call
    // clears it on its own entry, parses its LHS, and the inner's flag
    // survives to the post-RHS check_no_arrow_rhs() in the outer for-loop.
    bool saw_binary_op = false;

    // ES2021 §13.13: `??` is not just another precedence level, it is a
    // separate production whose operands may not be an unparenthesized
    // `&&` / `||`:
    //   CoalesceExpression : CoalesceExpressionHead ?? BitwiseORExpression
    //   ShortCircuitExpression : LogicalORExpression | CoalesceExpression
    // so `a && b ?? c` and `a ?? b || c` are both SyntaxErrors, in either
    // order, and parentheses are required to disambiguate. `??` and `||` sit
    // on adjacent precedence levels here, which would silently accept the mix,
    // so the two are tracked separately within one binary_expr invocation. A
    // parenthesized operand is parsed by a nested invocation with its own
    // flags, which is exactly why `(a && b) ?? c` stays legal.
    bool saw_logical_and_or = false;
    bool saw_nullish = false;

    for (;;) {
        self.last_was_local_var = false;
        TokenType tt = self.peek_type();
        int prec = get_binary_precedence(tt);

        if (prec < min_prec) {
            break;
        }
        // A bare `yield` closed by a line terminator is a complete
        // YieldExpression (§15.5), so it cannot become a binary operator's
        // left operand. Stop the expression here rather than erroring: the
        // statement level then applies ASI, which is what keeps
        // `yield \n + 1` legal (a fresh `+1` ExpressionStatement) while
        // `yield \n * 1` fails, `*` being unable to start a statement.
        if (left_was_newline_yield) {
            break;
        }
        // `[~In]`: inside a C-style for head an unparenthesized `in` would be
        // ambiguous with a for-in head, so the grammar simply has no
        // production for it (§14.7.4). Reject rather than break — unlike ASI
        // there is no shorter parse to fall back to, the next token in the
        // head must be `;`.
        if (tt == TokenType.IN && no_in) {
            return self.fail("'in' is not allowed in a for-statement head")~;
        }
        // Record that at least one binary operator was consumed. The value of
        // this expression is then the operator's result — never a Reference —
        // so the reference markers are cleared once, after the loop, no matter
        // which operator form (LOG_AND / LOG_OR / NULLISH / regular) ran.
        // Clearing here instead would not work: each form parses its right
        // operand afterwards, and that parse sets the flags again from its own
        // last operand (`a + b = 1` would inherit `b`'s getvar state).
        saw_binary_op = true;

        // ES2024 §13.6:
        //   ExponentiationExpression :
        //       UnaryExpression
        //       UpdateExpression ** ExponentiationExpression
        // The left operand of `**` is an UpdateExpression, so a UnaryExpression
        // there is a SyntaxError — the grammar refuses to guess between
        // `(-a) ** b` and `-(a ** b)`. Parenthesising either way makes the
        // operand a PrimaryExpression and is the documented workaround.
        // `a ** -b` is unaffected: the RIGHT operand is a full
        // ExponentiationExpression, which does derive UnaryExpression, and
        // `++a ** b` / `a++ ** b` are UpdateExpressions, so unary_expr does
        // not flag them.
        if (tt == TokenType.STARSTAR && left_was_unary_op) {
            return self.fail("unary operator not allowed on the left of '**'")~;
        }
        // From here on `left` is this operator's result, not the bare unary
        // expression the loop started with, so the guard must not fire on a
        // later iteration: `1 - 2 ** 2` parses as `1 - (2 ** 2)`.
        left_was_unary_op = false;

        // Enforce the CoalesceExpression / LogicalORExpression split described
        // above, before either operator form consumes its token.
        if (tt == TokenType.LOG_AND || tt == TokenType.LOG_OR) {
            if (saw_nullish) {
                return self.fail("'??' cannot be mixed with '&&' or '||' without parentheses")~;
            }
            saw_logical_and_or = true;
        } else if (tt == TokenType.NULLISH) {
            if (saw_logical_and_or) {
                return self.fail("'??' cannot be mixed with '&&' or '||' without parentheses")~;
            }
            saw_nullish = true;
        }

        // Handle short-circuit operators specially
        if (tt == TokenType.LOG_AND) {
            self.advance()!;
            // Result merges into `left`'s register, if that is a live local
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
            self.check_no_arrow_rhs();
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
            self.check_no_arrow_rhs();
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

            // Not nullish, skip right side
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch null and undefined jumps to here (right side)
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);

            // `CoalesceExpression : CoalesceExpressionHead ?? BitwiseORExpression`
            // (§13.13), so the right operand stops BELOW `&&` / `||` rather
            // than at `prec + 1`, which is PREC_LOGICAL_OR and would swallow
            // them. That makes `a ?? b || c` fail: the `||` is left unconsumed
            // and surfaces at this loop's next iteration, where the
            // saw_nullish guard rejects it. `a ?? (b || c)` is unaffected —
            // the parentheses make the operand a PrimaryExpression.
            ushort right = self.binary_expr(PREC_BITWISE_OR)!;
            self.check_no_arrow_rhs();
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

        // Preserve the LEFT OPERAND'S VALUE across the right operand's
        // evaluation. `a op b` must use a's value as it was *before* b runs
        // (the spec's GetValue(lref) precedes b's evaluation), but when `left`
        // is a live local's home register an assignment to that same variable
        // inside b overwrites it in place. `(w = 2) * (w = 3)` emitted
        //     LDINT r0, +2 / LDINT r0, +3 / MUL r1 = r0, r0
        // and computed 3 * 3 = 9 instead of 6.
        //
        // This is a *different* concern from the destination selection below,
        // which picks a register the RESULT may safely land in. That choice
        // must stay where it is, after the right operand has been parsed,
        // because it consumes the register the right operand just released;
        // hoisting it up here instead reassigns the result register and
        // destroys parameters (`n - 1` inside `fib` became `SUBI r0 = r0, r1`,
        // overwriting `n`). Hence two separate copies, gated separately.
        //
        // The value copy is emitted only when the right operand can actually
        // write a register, so ordinary code, meaning every arithmetic
        // expression in a hot loop, is unaffected and its bytecode is identical.
        // rhs_may_write_registers over-approximates: a false positive costs
        // one LDREG in a rare shape, a false negative is a miscompile.
        if (left_is_local && self.rhs_may_write_registers()) {
            ushort keep = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)keep, (uint)left, 0);
            left = keep;
            left_is_local = false;
        }

        ushort right = self.binary_expr(next_prec)!;
        self.check_no_arrow_rhs();
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
    // ES §13.15.1: a RelationalExpression / EqualityExpression / additive /
    // multiplicative / logical / coalesce result has AssignmentTargetType
    // ~invalid~. When any operator was consumed above, `left` holds a computed
    // value, so drop the reference markers the final right operand left behind
    // — otherwise assignment_expr's SimpleAssignmentTarget check sees that
    // operand's state and accepts `x + y = 1` or `(a === b) = 1`.
    if (saw_binary_op) {
        self.clear_ref_markers();
    }
    return left;
}

/// Drop the "the expression just parsed was a Reference" markers.
///
/// assignment_expr, postfix_expr and the prefix `++`/`--` path accept a target
/// only when one of these is set, so clearing them is how an operator whose
/// result is a value (AssignmentTargetType ~invalid~, ES §13.15.1) makes
/// `<expr> = 1` a SyntaxError. Kept as one helper because the markers must move
/// together — an operator that cleared only some of them would still let the
/// stale one through.
fn void CompilerContext.clear_ref_markers(&self) {
    self.last_was_getvar = false;
    self.last_was_member = false;
    self.last_was_local_var = false;
    // Dropping every marker already makes the target check fail, so the
    // separate ~invalid~ verdict has done its job and must not linger: a stale
    // `true` would wrongly reject the NEXT target parsed before any marker is
    // re-established.
    self.last_target_invalid = false;
}

/// Parse a unary expression.
fn ushort? CompilerContext.unary_expr(&self) {
    TokenType tt = self.peek_type();

    // A unary operator's operand is a UnaryExpression, which does not derive
    // YieldExpression, so `!yield` / `void yield` / `typeof yield` are
    // SyntaxErrors. Drop the permission for every operator case below; the
    // fall-through (no unary operator, so this IS still the head of the
    // enclosing AssignmentExpression) restores it before postfix_expr.
    bool yield_ok = self.yield_ok_here;
    self.yield_ok_here = false;

    // Whether a unary OPERATOR is about to be consumed, so binary_expr can
    // reject `-a ** b`: `**`'s left operand is an UpdateExpression, not a
    // UnaryExpression (§13.6). `++a ** b` and `a++ ** b` stay legal — they ARE
    // UpdateExpressions — hence the explicit operator list rather than "did we
    // take a non-default branch".
    //
    // Applied to self.last_was_unary_op by the wrapper below rather than here:
    // every operator case recurses into unary_expr for its operand, and that
    // inner call would overwrite the field with the OPERAND's shape
    // (`-3`'s inner `3` clearing the flag the outer `-` had just set).
    bool is_unary_op = tt == TokenType.MINUS || tt == TokenType.PLUS
            || tt == TokenType.LOG_NOT || tt == TokenType.BIT_NOT
            || tt == TokenType.TYPEOF || tt == TokenType.VOID
            || tt == TokenType.DELETE || tt == TokenType.AWAIT;
    ushort result_reg = self.unary_expr_inner(tt, yield_ok)!;
    self.last_was_unary_op = is_unary_op;
    return result_reg;
}

/// The body of unary_expr: dispatches on the already-peeked leading token.
/// Split out so unary_expr can set last_was_unary_op AFTER the recursive
/// operand parse, which would otherwise clobber it.
fn ushort? CompilerContext.unary_expr_inner(&self, TokenType tt, bool yield_ok) {
    switch (tt) {
        // ES §13.5: a UnaryExpression's value is the operator's result, never
        // a Reference (AssignmentTargetType ~invalid~). clear_ref_markers drops
        // the operand's getvar/member/local state so assignment_expr rejects
        // `-a = 1`, `!a = 1`, `~a = 1`, `+a = 1`.
        case TokenType.MINUS:
            self.advance()!;
            ushort operand = self.unary_expr()!;
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.UNM, (uint)result, (uint)operand, 0);
            self.free_reg(operand);
            self.clear_ref_markers();
            return result;

        case TokenType.PLUS:
            self.advance()!;
            ushort op_plus = self.unary_expr()!;
            ushort res_plus = self.alloc_reg();
            self.emit_abc(Opcode.UNP, (uint)res_plus, (uint)op_plus, 0);
            self.free_reg(op_plus);
            self.clear_ref_markers();
            return res_plus;

        case TokenType.LOG_NOT:
            self.advance()!;
            ushort op_not = self.unary_expr()!;
            ushort res_not = self.alloc_reg();
            self.emit_abc(Opcode.LNOT, (uint)res_not, (uint)op_not, 0);
            self.free_reg(op_not);
            self.clear_ref_markers();
            return res_not;

        case TokenType.BIT_NOT:
            self.advance()!;
            ushort op_bnot = self.unary_expr()!;
            ushort res_bnot = self.alloc_reg();
            self.emit_abc(Opcode.BNOT, (uint)res_bnot, (uint)op_bnot, 0);
            self.free_reg(op_bnot);
            self.clear_ref_markers();
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
            // IdentifierReference for this purpose, CoverParenthesizedExpression
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
                    // `( IDENTIFIER )` followed by a member/call/template
                    // continuation (`typeof (a).b`, `typeof (a)?.b`,
                    // `typeof (a)[0]`, `typeof (a)()`, `typeof (a)\`x\``)
                    // is not a bare identifier reference: the fast path
                    // would emit TYPEOFIDENT for `a` and leave the
                    // continuation dangling. Restore and fall through to
                    // normal typeof expression parsing.
                    Token? cont_opt = self.lexer.peek();
                    if (try ct = cont_opt) {
                        if (ct.type == TokenType.DOT || ct.type == TokenType.LBRACKET
                            || ct.type == TokenType.LPAREN || ct.type == TokenType.OPT_CHAIN
                            || ct.type == TokenType.TEMPLATE
                            || ct.type == TokenType.TEMPLATE_HEAD
                            || (ct.type == TokenType.STRING && ct.is_template)) {
                            matched = false;
                        }
                    }
                }
                if (matched) {
                    Token idTok2 = matched_id;
                    // A TS postfix cast/satisfies (`typeof (v) as T`) must not
                    // strand the cast keyword after the fast path's return;
                    // fall through to the normal path when one follows.
                    Token? cast_opt = self.lexer.peek();
                    if (try ct2 = cast_opt) {
                        if (ct2.type == TokenType.LOG_NOT
                            || (ct2.type == TokenType.IDENTIFIER && self.lexer.ts_mode
                                && (ident_is(ct2.str_value, "as")
                                    || ident_is(ct2.str_value, "satisfies")))) {
                            matched = false;
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
                    // The bare-identifier fast paths here bypass primary_expr,
                    // so they must repeat its `arguments` bookkeeping.
                    self.note_arguments_reference(idTok2.str_value)!;
                    uint name_idx = self.add_string_constant(idTok2.str_value);
                    ushort res_typeof = self.alloc_reg();
                    self.emit_a_bc(Opcode.TYPEOFIDENT, (uint)res_typeof, name_idx);
                    return res_typeof;
                }

                // Not the simple `( IDENTIFIER )` shape, restore and fall
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
                        bool is_ts_postfix = false;
                        if (try tok2 = peeked2) {
                            is_member = tok2.type == TokenType.DOT ||
                                        tok2.type == TokenType.LBRACKET ||
                                        tok2.type == TokenType.LPAREN ||
                                        tok2.type == TokenType.OPT_CHAIN ||
                                        tok2.type == TokenType.TEMPLATE ||
                                        tok2.type == TokenType.TEMPLATE_HEAD ||
                                        (tok2.type == TokenType.STRING && tok2.is_template);
                            is_ts_postfix = self.lexer.ts_mode
                                && (tok2.type == TokenType.LOG_NOT
                                    || (tok2.type == TokenType.IDENTIFIER
                                        && (ident_is(tok2.str_value, "as")
                                            || ident_is(tok2.str_value, "satisfies"))));
                        }
                        if (is_member || is_ts_postfix) {
                            // Not a plain bare identifier (member/call/template
                            // follows, or a TS cast/assertion the fast path
                            // would strand): push back and fall through to
                            // normal typeof expr parsing, whose postfix
                            // handling erases `as T` / `!`.
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
                            // This fast path bypasses primary_expr, so it must
                            // repeat its `arguments` bookkeeping.
                            self.note_arguments_reference(idTok.str_value)!;
                            uint name_idx = self.add_string_constant(idTok.str_value);
                            ushort res_typeof = self.alloc_reg();
                            self.emit_a_bc(Opcode.TYPEOFIDENT, (uint)res_typeof, name_idx);
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
            // three) rather than allocating a new register on top, that
            // would sit above prop/obj and make freeing them no-ops, since
            // free_reg only pops the top of the LIFO register stack.
            if (self.last_was_member) {
                ushort obj_reg = self.last_member_obj_reg;
                ushort prop_reg = self.last_member_prop_reg;
                bool obj_is_local = self.last_member_obj_is_local;
                self.last_was_member = false;
                if (obj_is_local) {
                    // obj_reg is a live local variable (e.g. `typeof d.value`):
                    // it must NOT be clobbered, writing the TYPEOF result into
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
            // void result is never a Reference, clear tracking so
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
                    // always throws ReferenceError, super references are not deletable.
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
                    self.emit_a_bc(Opcode.THROW_REF, (uint)err_reg, msg_idx);
                    return err_reg;
                }
                // Patch the last emitted instruction from GETPROP (or
                // GETPROP_CACHE, computed keys always emit the _CACHE
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
                // Like every other UnaryExpression (§13.5), a `delete` yields
                // the operator's boolean result, never a Reference, so its
                // AssignmentTargetType is ~invalid~ and `delete x.y = 1` is a
                // SyntaxError. Only last_was_member was being cleared here —
                // enough to stop the member store path, but the getvar/local
                // markers left over from the operand still made it look like a
                // valid assignment target.
                self.clear_ref_markers();
                self.last_lhs_name_len = 0;
                // op_del is the A register of the patched DELPROP (boolean).
                return op_del;
            } else if (self.last_was_getvar || self.last_was_local_var) {
                // `delete IdentifierReference`, Annex B.3.1 (ES5 11.4.1 step 1):
                // strict mode rejects this as a SyntaxError. Sloppy mode runs
                // the deletion against the variable environment. Since this
                // engine is strict-only, we always reject. Both operand shapes
                // must be caught: a name that resolved to a register
                // (last_was_local_var) is just as much an IdentifierReference
                // as one that needs a runtime GETVAR/GETGLOBAL.
                self.last_was_getvar = false;
                self.last_was_local_var = false;
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
            if (self.last_target_invalid || (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var)) {
                return COMPILE_ERROR~;
            }
            // ES5 §11.4.4 strict mode: ++eval / ++arguments is a SyntaxError.
            // `await`/`yield` are reserved only in their respective async /
            // generator contexts; see the matching check in assignment_expr.
            if (!self.last_was_member && self.last_lhs_name_len > 0
                && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len],
                                      self.is_async || self.is_module || self.forbid_await)) {
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
            bool inc_was_getglobal = self.last_was_getvar && self.last_was_getglobal;
            bool inc_was_getglobal_prim = inc_was_getglobal && self.last_was_getglobal_prim;
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
            } else if (inc_was_getvar && !inc_was_getglobal && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                // Replace GETVAR with INC_VAR: 1 dispatch instead of 3
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, getvar_reg, name_idx);
            } else if (inc_was_getglobal && self.code_count > 0
                && (self.code[self.code_count - 1].op == Opcode.GETGLOBAL
                    || self.code[self.code_count - 1].op == Opcode.GETGLOBAL_PRIM)) {
                // Replace GETGLOBAL/GETGLOBAL_PRIM with INC_GLOBAL: 1 lean
                // dispatch. INC_GLOBAL's in-place numeric update is correct for
                // any global (prim or not), so it subsumes the PRIM read too.
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getglobal_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_GLOBAL, getglobal_reg, name_idx);
            } else {
                // Register-cached local. Mirror the postfix INC path: route
                // through INC_VAR when `op_inc` is a CONST binding's home
                // register, so the runtime env walk throws TypeError.
                uint const_ni = self.find_const_name_idx(op_inc);
                if (const_ni != 0xFFFFFFFFu) {
                    self.emit_a_bc(Opcode.INC_VAR, (uint)op_inc, const_ni);
                } else {
                    self.emit_abc(Opcode.INC, (uint)op_inc, 0, 0);
                    if (inc_was_getvar) {
                        Opcode inc_store = inc_was_getglobal_prim ? Opcode.PUTGLOBAL_PRIM
                            : (inc_was_getglobal ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN);
                        self.emit_a_bc(inc_store, (uint)op_inc, inc_getvar_name_idx);
                    }
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
            if (self.last_target_invalid || (!self.last_was_member && !self.last_was_getvar && !self.last_was_local_var)) {
                return COMPILE_ERROR~;
            }
            // ES5 §11.4.5 strict mode: --eval / --arguments is a SyntaxError.
            // `await`/`yield` are reserved only in their respective async /
            // generator contexts; see the matching check in assignment_expr.
            if (!self.last_was_member && self.last_lhs_name_len > 0
                && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len],
                                      self.is_async || self.is_module || self.forbid_await)) {
                return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
            }
            // See INC case above for why member takes priority over getvar.
            bool dec_was_getvar = self.last_was_getvar;
            bool dec_was_getglobal = self.last_was_getvar && self.last_was_getglobal;
            bool dec_was_getglobal_prim = dec_was_getglobal && self.last_was_getglobal_prim;
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
            } else if (dec_was_getvar && !dec_was_getglobal && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, getvar_reg, name_idx);
            } else if (dec_was_getglobal && self.code_count > 0
                && (self.code[self.code_count - 1].op == Opcode.GETGLOBAL
                    || self.code[self.code_count - 1].op == Opcode.GETGLOBAL_PRIM)) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getglobal_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_GLOBAL, getglobal_reg, name_idx);
            } else {
                // Register-cached local. Mirror the postfix DEC path: route
                // through DEC_VAR when `op_dec` is a CONST binding's home
                // register so the runtime env walk throws TypeError.
                uint const_ni = self.find_const_name_idx(op_dec);
                if (const_ni != 0xFFFFFFFFu) {
                    self.emit_a_bc(Opcode.DEC_VAR, (uint)op_dec, const_ni);
                } else {
                    self.emit_abc(Opcode.DEC, (uint)op_dec, 0, 0);
                    if (dec_was_getvar) {
                        Opcode dec_store = dec_was_getglobal_prim ? Opcode.PUTGLOBAL_PRIM
                            : (dec_was_getglobal ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN);
                        self.emit_a_bc(dec_store, (uint)op_dec, dec_getvar_name_idx);
                    }
                }
            }
            self.last_was_getvar = false;
            self.last_was_member = false;
            return op_dec;

        case TokenType.NEW: {
            // Returns without passing through postfix_expr, so the TS postfix
            // erasure (`new X() as T`) must run explicitly.
            ushort new_reg = self.new_expr()!;
            if (self.lexer.ts_mode) {
                self.ts_skip_postfix_type_ops()!;
            }
            return new_reg;
        }

        default:
            // No unary operator was consumed, so this is still the head of the
            // enclosing AssignmentExpression and a YieldExpression may start
            // here.
            self.yield_ok_here = yield_ok;
            return self.postfix_expr()!;
    }
}

/// After a postfix ++/-- token has been consumed, decide whether the update
/// result is actually discarded. Only valid when the caller already holds a
/// true postfix_void signal (statement / for-update position). The token now at
/// the cursor is whatever follows the ++/--: any binary/assignment/ternary/comma
/// operator (or `(`, `[`, `.`) would consume the produced value, so we skip the
/// materialization only for the clear statement/clause terminators. A newline
/// after the ++/-- means ASI ends the statement here, which also discards it.
fn bool CompilerContext.postfix_result_discarded(&self) {
    if (self.lexer.seen_line_term) return true;
    TokenType next = self.peek_type();
    return next == TokenType.SEMICOLON
        || next == TokenType.RPAREN
        || next == TokenType.RBRACE
        || next == TokenType.EOF_TOKEN;
}

/// Parse postfix expressions (++, --).
///
/// NOTE: We deliberately do NOT set `self.lhs_mode = true` here. Doing so
/// would change how `member_expr` behaves for ALL nested member expressions
/// inside `call_expr`, including callees of method calls like `foo.bar()`,
/// keeping their obj/prop registers alive and marking them as LHS members,
/// which breaks unrelated code. Instead we let `member_expr` always track
/// `last_was_member` (and save obj/prop registers), let `call_expr` clear
/// `last_was_member` after emitting a call, and then inspect the flag here
/// to decide whether to emit INC/DEC + PUTPROP for a member LHS.
///
/// TypeScript postfix erasable syntax after a completed expression:
/// non-null `!`, `as T`, `satisfies T`, chainable (`x as unknown as T`).
/// Consumed without emitting anything. ts_mode only.
fn void? CompilerContext.ts_skip_postfix_type_ops(&self) {
    for (;;) {
        TokenType tt2 = self.peek_type();
        if (tt2 == TokenType.LOG_NOT) {
            // Non-null postfix `!`. `!x` (unary) is a prefix on a fresh
            // operand; here a primary is already parsed, so the `!` is
            // postfix and can be consumed unconditionally.
            Token _bang = self.advance()!;
            continue;
        }
        if (tt2 == TokenType.IDENTIFIER) {
            if (self.check_ts_ident("as") || self.check_ts_ident("satisfies")) {
                // check_ts_ident (not match_ts_ident) because the failed
                // probe would consume+pushback the identifier, and when this
                // expression runs inside a nested compile context (class
                // field initializer), the pushback would land on the nested
                // context's stack, invisible to the caller that reads the
                // shared lexer.
                Token _kw = self.advance()!;
                // `as const` — `const` is a keyword, not a type name, so
                // skip_type would stop on it immediately.
                if (self.match(TokenType.CONST)) continue;
                self.skip_type()!;
                continue;
            }
        }
        break;
    }
}

///
/// For a member LHS (e.g. `obj.prop++`), the GETPROP emitted by member_expr
/// is still in the bytecode stream. We NOP it (its result is now in `saved`
/// and we will overwrite `operand` with INC) and use the saved obj/prop
/// registers to emit a follow-up PUTPROP that writes the new value back.
fn ushort? CompilerContext.postfix_expr(&self) {
    // Consume the discarded-result signal once, before descending. Clearing it
    // here means any nested sub-expression reached via call_expr (subscripts,
    // call arguments) sees postfix_void=false, only the outermost postfix in
    // the statement/for-update descent can skip old-value materialization.
    bool result_discarded = self.postfix_void;
    self.postfix_void = false;

    ushort operand = self.call_expr()!;

    // TypeScript postfix erasable syntax: non-null `!`, `as T`, `satisfies T`.
    // Loop because they can chain: `x as unknown as T`.
    if (self.lexer.ts_mode) {
        self.ts_skip_postfix_type_ops()!;
    }

    bool lhs_was_getvar = self.last_was_getvar;
    bool lhs_was_getglobal = self.last_was_getvar && self.last_was_getglobal;
    bool lhs_was_getglobal_prim = lhs_was_getglobal && self.last_was_getglobal_prim;
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
    // and other non-reference results are not, reject as an early
    // SyntaxError rather than silently discarding the increment/decrement.
    // §13.4.1 words it as "It is an early Syntax Error if the
    // AssignmentTargetType of LeftHandSideExpression is invalid", the same
    // test the assignment path uses; see the Annex B.3.9 / web-compat note in
    // assignment_expr_inner for why `f()++` is an early error here even though
    // node defers it to a runtime ReferenceError.
    if ((tt == TokenType.INC || tt == TokenType.DEC) && !nl_before_postfix_op) {
        if (self.last_target_invalid || (!self.last_was_member && !lhs_was_getvar && !self.last_was_local_var)) {
            return COMPILE_ERROR~;
        }
        // ES5 §11.3.1/§11.3.2 strict mode: eval++ / arguments-- is a SyntaxError.
        // `await`/`yield` are reserved only in their respective async /
        // generator contexts; see the matching check in assignment_expr.
        if (!self.last_was_member && self.last_lhs_name_len > 0
            && is_restricted_name(self.last_lhs_name_buf[:self.last_lhs_name_len],
                                  self.is_async || self.is_module || self.forbid_await)) {
            return self.fail("Assignment to eval or arguments is not allowed in strict mode")~;
        }
    }
    if (tt == TokenType.INC && !nl_before_postfix_op) {
        if (self.last_was_optional_chain) {
            return COMPILE_ERROR~;
        }
        self.advance()!;
        // When the result is provably discarded (see postfix_result_discarded),
        // skip the old-value materialization entirely and compile identically to
        // the prefix form: no LDREG/TONUMERIC, and GETVAR/GETGLOBAL is rewritten
        // in place to INC_VAR/INC_GLOBAL (single instruction, no trailing NOP).
        if (result_discarded && self.postfix_result_discarded()) {
            if (self.last_was_member) {
                ushort obj_reg = self.last_member_obj_reg;
                ushort prop_reg = self.last_member_prop_reg;
                self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)prop_reg, (uint)operand);
                self.free_reg(prop_reg);
                self.free_reg(obj_reg);
            } else if (lhs_was_getvar && !lhs_was_getglobal && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, getvar_reg, name_idx);
            } else if (lhs_was_getglobal && self.code_count > 0
                && (self.code[self.code_count - 1].op == Opcode.GETGLOBAL
                    || self.code[self.code_count - 1].op == Opcode.GETGLOBAL_PRIM)) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getglobal_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_GLOBAL, getglobal_reg, name_idx);
            } else {
                // Register-cached local (no GETVAR was emitted). The bare INC
                // opcode only mutates the register and would silently succeed on
                // a const violation. If `operand` is a CONST binding, route the
                // write through INC_VAR, the runtime walks the env, finds the
                // non-writable flag installed by the surviving PUTLEX_C, and
                // throws TypeError (plan 062 group H).
                uint const_ni = self.find_const_name_idx(operand);
                if (const_ni != 0xFFFFFFFFu) {
                    self.emit_a_bc(Opcode.INC_VAR, (uint)operand, const_ni);
                } else {
                    self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
                    if (lhs_was_getvar) {
                        Opcode pf_store = lhs_was_getglobal_prim ? Opcode.PUTGLOBAL_PRIM
                            : (lhs_was_getglobal ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN);
                        self.emit_a_bc(pf_store, (uint)operand, lhs_getvar_name_idx);
                    }
                }
            }
            self.last_was_getvar = false;
            self.last_was_member = false;
            return operand;
        }
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
            if (lhs_was_getglobal) {
                self.emit_a_bc(Opcode.INC_GLOBAL, (uint)operand, lhs_getvar_name_idx);
                self.emit_abc(Opcode.NOP, 0, 0, 0);
            } else if (lhs_was_getvar) {
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
        // Discarded result: compile like prefix (no old-value materialization).
        // See the INC case above for the rationale.
        if (result_discarded && self.postfix_result_discarded()) {
            if (self.last_was_member) {
                ushort obj_reg = self.last_member_obj_reg;
                ushort prop_reg = self.last_member_prop_reg;
                self.emit_abc(Opcode.DEC, (uint)operand, 0, 0);
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)prop_reg, (uint)operand);
                self.free_reg(prop_reg);
                self.free_reg(obj_reg);
            } else if (lhs_was_getvar && !lhs_was_getglobal && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getvar_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, getvar_reg, name_idx);
            } else if (lhs_was_getglobal && self.code_count > 0
                && (self.code[self.code_count - 1].op == Opcode.GETGLOBAL
                    || self.code[self.code_count - 1].op == Opcode.GETGLOBAL_PRIM)) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                uint getglobal_reg = self.code[self.code_count - 1].a;
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_GLOBAL, getglobal_reg, name_idx);
            } else {
                // Register-cached local. Mirror the INC postfix branch: route
                // the write through DEC_VAR when `operand` is a CONST binding so
                // the runtime env walk throws TypeError on assignment.
                uint const_ni = self.find_const_name_idx(operand);
                if (const_ni != 0xFFFFFFFFu) {
                    self.emit_a_bc(Opcode.DEC_VAR, (uint)operand, const_ni);
                } else {
                    self.emit_abc(Opcode.DEC, (uint)operand, 0, 0);
                    if (lhs_was_getvar) {
                        Opcode pf_store = lhs_was_getglobal_prim ? Opcode.PUTGLOBAL_PRIM
                            : (lhs_was_getglobal ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN);
                        self.emit_a_bc(pf_store, (uint)operand, lhs_getvar_name_idx);
                    }
                }
            }
            self.last_was_getvar = false;
            self.last_was_member = false;
            return operand;
        }
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
            if (lhs_was_getglobal) {
                self.emit_a_bc(Opcode.DEC_GLOBAL, (uint)operand, lhs_getvar_name_idx);
                self.emit_abc(Opcode.NOP, 0, 0, 0);
            } else if (lhs_was_getvar) {
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

/// After the ')' of a grouping expression: decide whether a pending
/// member-call receiver survives the parens. Member accesses, optional
/// chains included, keep their Reference through parens (`(o.m)()` and
/// `(o?.b)()` both call with this=o; test262
/// optional-chaining/optional-call-preserves-this.js). A short-circuited
/// chain yields undefined and the call throws regardless, so no receiver
/// handling is needed for that case. The receiver is dropped only when
/// nothing call-like follows, the parenthesized value is consumed as
/// plain data.
fn void CompilerContext.drop_paren_receiver_unless_ref(&self) {
    TokenType next_tt = self.peek_type();
    bool call_follows = next_tt == TokenType.LPAREN || next_tt == TokenType.OPT_CHAIN;
    if (!call_follows && self.call_prop_obj_reg != REG_NONE) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }
}

/// Parse call expressions: f(), f(a,b), obj.method(), obj[expr](), tag`...`.
fn ushort? CompilerContext.call_expr(&self) {
    self.last_was_optional_chain = false;
    ushort callee = self.member_expr()!;

    // If member_expr saved a property object but next token is not a call,
    // free the object register now. Inside parenthesized expressions, defer
    // this decision to the paren handler (which sees what follows the parens).
    if (self.call_prop_obj_reg != REG_NONE
        && !self.inside_parens
        && !self.check(TokenType.LPAREN)
        && !self.check(TokenType.OPT_CHAIN)
        && !self.is_next_template()) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }

    // Optional chaining short-circuit jump tracking
    uint[16] opt_jump_addrs;
    int opt_jump_count = 0;

    for (;;) {
        // TypeScript call-site type arguments: `f<T>(x)`. The `<` after a
        // callee is type args only when a balanced `<...>` is directly
        // followed by `(`; otherwise it's a comparison (left for binary_expr).
        if (self.lexer.ts_mode && self.check(TokenType.LT) && self.ts_peek_generics_lparen()) {
            self.skip_generic_params()!;
            continue;
        }
        // TypeScript non-null assertion postfix `!` (`o!.x`, `f()!`).
        // Consumed inside the chain loop so the `.`/`[`/`(` suffix after it
        // still parses; postfix_expr's own `!` case then only sees the
        // non-chaining forms and simply continues.
        if (self.lexer.ts_mode && self.check(TokenType.LOG_NOT)) {
            self.advance()!;
            continue;
        }
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
            if (self.call_prop_obj_reg != REG_NONE) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = REG_NONE;
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
            if (self.call_prop_obj_reg != REG_NONE) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = REG_NONE;
            }
        } else if (self.match(TokenType.DOT)) {
            if (self.check(TokenType.HASH_IDENT)) {
                // f().#name, private field access on a call result.
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok2 = self.advance()!;
                ushort priv_prop_reg = self.emit_private_access(priv_tok2.str_value, callee)!;
                ushort priv_result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP_PRIVATE, (uint)priv_result, (uint)callee, (uint)priv_prop_reg);

                if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN) || self.is_next_template()) {
                    self.free_reg(priv_prop_reg);
                    self.last_was_member = false;
                    self.call_prop_obj_reg = callee;
                } else {
                    self.last_was_member = true;
                    self.last_target_invalid = false;
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
            self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);

            // A property access on a call result is itself a MemberExpression
            // and a valid assignment/update target (`f().x = v`, `f().x++`).
            // Record it so assignment_expr/postfix_expr can emit PUTPROP,
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
                self.last_target_invalid = false;
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
            // case, ordering is unaffected. GETPROP_CACHE writes the
            // coerced key back into idx_reg; shield a live-local key from
            // that mutation first.
            idx_reg = self.shield_computed_key(idx_reg);

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP_CACHE, (uint)result, (uint)callee, (uint)idx_reg);

            // Computed member on a call result, also a valid target
            // (`f()[k] = v`). See the DOT branch above.
            if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN)) {
                self.free_reg(idx_reg);
                self.last_was_member = false;
                self.call_prop_obj_reg = callee;
            } else {
                self.last_was_member = true;
                self.last_target_invalid = false;
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
                // a?.(), clear direct eval flag, optional chain calls are never direct eval
                self.callee_is_eval = false;
                callee = self.emit_call(callee)!;
                self.last_was_member = false;
                self.last_was_getvar = false;
            } else if (self.match(TokenType.LBRACKET)) {
                // a?.[expr], result is never a referenceable member/target
                // (optional chains can't be assignment targets per spec), so
                // plain GETPROP suffices, no coerced-key cache needed.
                ushort idx_reg = self.expression()!;
                self.expect(TokenType.RBRACKET)!;

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)idx_reg);
                self.free_reg(idx_reg);

                self.last_was_member = false;
                self.last_was_getvar = false;
                // Save object for potential this binding (inner or outer call)
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = callee;
                callee = result;
            } else if (self.check(TokenType.HASH_IDENT)) {
                // a?.#name, short-circuits above on nullish `a`; on the live
                // path this is a normal (brand-checked) private field read.
                // Result is never a referenceable member/target, matching the
                // a?.prop case below.
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok3 = self.advance()!;
                ushort priv_prop_reg2 = self.emit_private_access(priv_tok3.str_value, callee)!;
                ushort priv_result2 = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP_PRIVATE, (uint)priv_result2, (uint)callee, (uint)priv_prop_reg2);
                self.free_reg(priv_prop_reg2);

                self.last_was_member = false;
                self.last_was_getvar = false;
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = callee;
                callee = priv_result2;
            } else {
                // a?.prop, result is never a referenceable member
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);

                ushort prop_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
                self.free_reg(prop_reg);

                self.last_was_member = false;
                self.last_was_getvar = false;
                // Save object for potential this binding (inner or outer call)
                if (self.call_prop_obj_reg != REG_NONE) {
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
    // CALL_VAR fusion candidate: the callee is a bare-identifier reference
    // (GETVAR emitted by primary_expr, not a local variable register) whose
    // producing instruction is still the one sitting at last_getvar_code_pos
    // and targets this exact callee register, with nothing emitted since.
    // Captured before anything below (eval detection, callee relocation, arg
    // compilation) can invalidate last_was_getvar / append to the code
    // array. The name's constant pool index must fit CALL_VAR's 8-bit C
    // field; larger indices fall back to plain GETVAR + CALL_UNDEF_THIS.
    // The `call_prop_obj_reg == REG_NONE` term is the same non-method
    // precondition getglobal_callee carries below, and for the same reason:
    // the strip below is only safe if CALL_VAR is actually reached, and the
    // CALL_VAR emission is guarded by `undef_this`, which is false whenever a
    // receiver register is pending. Without it, a stale call_prop_obj_reg
    // left by an enclosing property assignment made this strip the callee's
    // GETVAR and then emit a plain CALL, which read a register nothing had
    // written — a silent wrong-register call.
    bool getvar_callee = self.last_was_getvar
        && self.call_prop_obj_reg == REG_NONE
        && self.last_getvar_code_pos + 1 == self.code_count
        && self.code[self.last_getvar_code_pos].op == Opcode.GETVAR
        && self.code[self.last_getvar_code_pos].a == callee_reg
        && self.last_getvar_name_idx <= bytecode::MAX_C;
    // CALL_GLOBAL fusion candidate: the global-scope analog. The callee read
    // was emitted as plain GETGLOBAL (true global slot scope, non-prim-only
    // binding, GETGLOBAL_PRIM globals are never functions, so a callee is
    // always plain GETGLOBAL) and is still the last instruction targeting this
    // exact callee register. Fuses into CALL_GLOBAL, which reloads the callee
    // via GETGLOBAL's varref IC and calls in one dispatch.
    // last_was_getglobal (unlike last_was_getvar) is only cleared inside
    // emit_ident_read, so it can stay stale-true through a member-access
    // callee (a method call). Require call_prop_obj_reg == REG_NONE so
    // this fires only for a plain bare-global call, the same non-method
    // precondition that makes the CALL_GLOBAL emission below reachable.
    bool getglobal_callee = self.last_was_getvar
        && self.last_was_getglobal
        && self.call_prop_obj_reg == REG_NONE
        && self.last_getvar_code_pos + 1 == self.code_count
        && self.code[self.last_getvar_code_pos].op == Opcode.GETGLOBAL
        && self.code[self.last_getvar_code_pos].a == callee_reg
        && self.last_getvar_name_idx <= bytecode::MAX_C;
    uint getvar_code_pos = self.last_getvar_code_pos;
    uint getvar_name_idx = self.last_getvar_name_idx;

    self.expect(TokenType.LPAREN)!;

    // Detect direct eval: callee was the identifier `eval` (set by primary_expr)
    // and this is not a property call (obj.eval()).
    if (self.callee_is_eval && self.call_prop_obj_reg == REG_NONE) {
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
    // of the stack, the first call's result clobbers f).
    if (callee_reg + 1 < self.next_reg || self.is_local_var_reg(callee_reg)) {
        // Relocation invalidates the CALL_VAR fusion: the GETVAR at
        // getvar_code_pos wrote into the OLD callee_reg (about to be
        // superseded by this LDREG copy), so fusing would either read a
        // stale/freed register or require rewriting the relocation too.
        // Fall back to plain GETVAR + CALL_UNDEF_THIS for this call.
        getvar_callee = false;
        getglobal_callee = false;
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        // Account for the callee's new position so args don't overlap
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    } else if (getvar_callee || getglobal_callee) {
        // No relocation: the GETVAR/GETGLOBAL at getvar_code_pos is still the
        // last emitted instruction and nothing has read callee_reg's value yet
        // (arg compilation below only uses callee_reg as a register-number
        // anchor). Drop it from the code stream entirely, CALL_VAR/CALL_GLOBAL
        // at the end of this call will load the callee itself. This is what
        // actually elides the dispatch: the load's bytes never execute.
        self.code_count = getvar_code_pos;
    }
    // Place undefined 'this' slot (or the property object for method calls).
    // For a plain (non-method) call the receiver is always undefined; rather
    // than emit an `LDUNDEF callee_reg+1` here (a dispatch executed on every
    // call), we mark the call as CALL_UNDEF_THIS below and let the VM
    // materialize the undefined receiver directly in its call handler. The
    // this-slot register is still reserved (not written) so argument
    // allocation and the callee-relocation logic above stay correct.
    bool undef_this = false;
    if (self.call_prop_obj_reg != REG_NONE) {
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)self.call_prop_obj_reg, 0);
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    } else {
        undef_this = true;
        // Reserve the this-slot without writing it (the VM clears it): keep
        // next_reg past callee_reg+1 so arguments never alias the slot.
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Compile arguments into consecutive registers starting at first_arg
    ushort arg_count = 0;
    bool has_spread = false;
    ushort total_count_reg = REG_NONE;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for spread argument
            if (self.match(TokenType.ELLIPSIS)) {
                // The spread source's register depends on whether this is
                // the first spread (empty window, normal eval) or a later
                // one (window holds real arguments, eval into the reserved
                // region below first_arg).
                bool is_first_spread = !has_spread;
                if (!has_spread) {
                    has_spread = true;
                    // Shift the callee frame up by one and place the running-total
                    // register (SPREAD_ARG/PUTARG's B field, CALL_S's nargs source)
                    // in the freed low slot, below first_arg, so an unbounded
                    // spread cannot overwrite it or the arguments. Updates
                    // callee_reg / first_arg in place.
                    total_count_reg = self.begin_spread_args(&callee_reg, &first_arg, arg_count);
                    self.emit_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count);
                }
                ushort spread_reg = self.compile_spread_source(first_arg, arg_count, is_first_spread)!;

                // SPREAD_ARG: A=first_arg base reg, B=running-total reg (in/out;
                // the spread is written at first_arg + running_total and the
                // register is advanced by the number of elements produced),
                // C=source reg. This stacks multiple spreads (and interleaved
                // PUTARG args) in argument order.
                self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                self.free_reg(spread_reg);
            } else {
                ushort arg_reg;
                if (has_spread) {
                    // Non-spread arg following a spread, destination slot
                    // depends on the runtime spread count held in
                    // total_count_reg. PUTARG writes the value at
                    // regs[first_arg + total_count] and increments
                    // total_count. The spread has already run, so any
                    // register at or above first_arg may hold a real
                    // argument; compile the value into the reserved
                    // below-first_arg region instead, where the spread
                    // cannot reach it.
                    ushort saved_cap = self.reg_cap;
                    self.next_reg = self.spread_eval_base;
                    self.reg_cap = first_arg;
                    arg_reg = self.assignment_expr()!;
                    self.reg_cap = saved_cap;
                    self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                    self.free_reg(arg_reg);
                } else {
                    arg_reg = self.assignment_expr()!;
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

    // Emit CALL / CALL_S / CALL_UNDEF_THIS, reusing callee_reg as result
    // (callee+this consumed by call).
    if (has_spread) {
        // CALL_S reads nargs from a register and has no undef-this variant;
        // if we elided the this-slot write above, materialize it now so the
        // slow-path receiver read is correct.
        if (undef_this) {
            self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
        }
        // CALL_S reads the callee value from callee_reg directly (no
        // fused variant). If the GETVAR/GETGLOBAL was stripped speculatively
        // above (spread-ness is only known once args are fully parsed), restore
        // it here, CALL_S needs the real value in the register.
        if (getvar_callee) {
            self.emit_a_bc(Opcode.GETVAR, (uint)callee_reg, getvar_name_idx);
        } else if (getglobal_callee) {
            self.emit_a_bc(Opcode.GETGLOBAL, (uint)callee_reg, getvar_name_idx);
        }
        // CALL_S: A=result, B=callee_reg, C=nargs_reg, reuse callee_reg for result
        self.emit_abc(Opcode.CALL_S, (uint)callee_reg, (uint)callee_reg, (uint)total_count_reg);
    } else if (undef_this && getvar_callee) {
        // Fuse the callee's GETVAR into this call: the GETVAR instruction
        // was never actually emitted (call_expr removed it from the code
        // stream up front, before arg compilation), so CALL_VAR here is
        // the only dispatch that loads AND calls the callee. One dispatch
        // instead of two.
        self.emit_abc(Opcode.CALL_VAR, (uint)callee_reg, (uint)arg_count, getvar_name_idx);
    } else if (undef_this && getglobal_callee) {
        // Global-scope analog: the callee's GETGLOBAL was stripped above, so
        // CALL_GLOBAL is the only dispatch that loads (via GETGLOBAL's varref
        // IC) AND calls the global callee. One dispatch instead of two.
        self.emit_abc(Opcode.CALL_GLOBAL, (uint)callee_reg, (uint)arg_count, getvar_name_idx);
    } else if (undef_this) {
        // Plain non-method call: receiver is undefined, materialized by the VM
        // (no per-call LDUNDEF dispatch). A=result, B=callee_reg, C=nargs.
        self.emit_abc(Opcode.CALL_UNDEF_THIS, (uint)callee_reg, (uint)callee_reg, (uint)arg_count);
    } else {
        self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, (uint)arg_count);
    }

    // What just parsed is a CallExpression, not an ArrowFunction. An arrow
    // passed as an ARGUMENT (`a.every((x, i) => x > 0)`) leaves
    // last_was_arrow_expr set on the way out of assignment_expr, and nothing
    // between there and the enclosing binary_expr's post-RHS
    // check_no_arrow_rhs() cleared it — so `true && a.every((x,i) => x>0)`
    // was rejected as "arrow function in expression position not allowed".
    // The guard exists to reject a BARE arrow as a binary operand
    // (`1 + () => 2`); an arrow inside the call's parentheses is not that.
    self.last_was_arrow_expr = false;

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
    ushort obj_reg = REG_NONE;
    if (self.call_prop_obj_reg != REG_NONE) {
        obj_reg = self.call_prop_obj_reg;
        self.call_prop_obj_reg = REG_NONE;
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
    // GetTemplateObject, the cache is per Parse Node, not per closure).
    // The slot starts as `undefined`; the first evaluation builds and
    // freezes the array, then stores it back with SETCONST.
    TVal undef_tv;
    undef_tv.set_undefined();
    uint cache_idx = self.add_constant(undef_tv);

    ushort tmpl_arr_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.LDCONST, (uint)tmpl_arr_reg, cache_idx);
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
            self.emit_a_bc(Opcode.LDCONST, (uint)elem_reg, str_indices[i]);
        }
        ushort idx_reg = self.alloc_reg();
        self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i);
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)idx_reg, (uint)elem_reg);
        self.free_reg(elem_reg);
        self.free_reg(idx_reg);
    }
    self.emit_a_bc(Opcode.SETALEN, (uint)tmpl_arr_reg, part_count);

    // Create raw array (uncooked source text of each part)
    ushort raw_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)raw_arr_reg, 0, 0);

    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)str_reg, raw_indices[i]);
        ushort idx_reg = self.alloc_reg();
        self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i);
        self.emit_abc(Opcode.PUTPROP, (uint)raw_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit_a_bc(Opcode.SETALEN, (uint)raw_arr_reg, part_count);

    // Set .raw property on template array, a real but non-enumerable data
    // property (ES2015 §12.2.9.3 step 8: CreateDataProperty, then step 9
    // demotes it to non-writable/non-configurable via freeze below; own
    // enumerability is fixed at creation since freeze doesn't alter it).
    {
        uint raw_key_idx = self.add_string_constant("raw");
        ushort raw_key_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)raw_key_reg, raw_key_idx);
        self.emit_abc(Opcode.PUTPROP_NE, (uint)tmpl_arr_reg, (uint)raw_key_reg, (uint)raw_arr_reg);
        self.free_reg(raw_key_reg);
    }

    // Both arrays are frozen, non-configurable/non-writable integrity
    // level (ES2015 §12.2.9.3 steps 10-11).
    self.emit_abc(Opcode.FREEZEOBJ, (uint)raw_arr_reg, 0, 0);
    self.free_reg(raw_arr_reg);
    self.emit_abc(Opcode.FREEZEOBJ, (uint)tmpl_arr_reg, 0, 0);

    self.emit_a_bc(Opcode.SETCONST, (uint)tmpl_arr_reg, cache_idx);

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
    if (obj_reg != REG_NONE) {
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
        // `new.target` is a NewTarget meta-property, and both halves are
        // terminal symbols: `new.target` is a SyntaxError, not a
        // property read (ES2024 §13.3.12 / §5.1.5). The `new` half is already
        // covered by advance()'s escaped-keyword gate.
        if (target_tok.has_escape) {
            return self.fail("keyword must not contain escaped characters")~;
        }
        if (target_name.len == 6
            && target_name[0] == 't'
            && target_name[1] == 'a'
            && target_name[2] == 'r'
            && target_name[3] == 'g'
            && target_name[4] == 'e'
            && target_name[5] == 't') {
            // ES2015 Annex B / §14.2.1: `new.target` is a SyntaxError in
            // any of these contexts:
            //   - eval source from a non-direct eval (indirect eval)
            //   - eval source from script top-level (even direct)
            //   - eval source from inside an ArrowFunction (even direct)
            // and is only permitted inside an eval source that is being
            // processed by direct eval whose call site sits inside a
            // non-ArrowFunction's FunctionBody. compile_eval sets
            // in_eval_code=true and eval_direct_in_function=true ONLY in
            // that last case, so a missing flag means we must reject.
            // in_eval_code (not eval_mode) is the right test here: it also
            // holds inside an arrow nested in the eval source, which is
            // exactly where the arrow inherits the eval code's [[NewTarget]].
            //
            // We also reject when not in eval code AND not otherwise in
            // a constructable context (e.g. class constructor), global
            // / module / function code outside a constructor body has no
            // [[NewTarget]] either (ES2015 §13.3.1.1 step 1 / step 5).
            // Top-level code is already rejected by is_global + !constructable,
            // but inside a class constructor the NEWTARGET opcode is the
            // correct implementation of `new.target` (returns the
            // constructor itself).
            if (self.in_eval_code && !self.eval_direct_in_function) {
                // Indirect eval, global eval, or eval from arrow:
                // new.target is a SyntaxError per spec.
                self.record_error("new.target is not allowed in this eval context");
                return COMPILE_ERROR~;
            }
            // §16.1.1 (Script) and §16.2.1.1 (Module): it is a Syntax Error
            // for a StatementList to Contain NewTarget at all, the sole
            // exception being the direct-eval-inside-a-non-arrow-function case
            // handled just above. Top-level code has no [[NewTarget]], and
            // neither does an arrow written there: an arrow inherits
            // new.target from its enclosing function, and there is none.
            if ((self.is_global || self.no_new_target) && !self.in_eval_code) {
                return self.fail("new.target is only allowed in function code")~;
            }
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.NEWTARGET, (uint)result_reg, 0, 0);
            ctor_reg = result_reg;
        } else {
            // Not 'target', error
            self.record_error("expected 'target' after 'new.'");
            return COMPILE_ERROR~;
        }
    } else {
        // `new`'s callee is a MemberExpression (ES2024 §13.3): both
        // `MemberExpression : new MemberExpression Arguments` and
        // `NewExpression : new NewExpression` bottom out there. ImportCall is
        // listed only under CallExpression, and there is no
        // `MemberExpression : CallExpression` production, so no `new` callee
        // can ever contain a bare ImportCall — `new import('')` is a
        // SyntaxError, and so is a property access chained onto it
        // (`new import('').then`), because the chain would have to be
        // `CallExpression . IdentifierName`, which is still a CallExpression.
        //
        // MetaProperty IS a MemberExpression production, so `new import.meta`
        // and `new import.meta.foo` parse fine and fail at RUNTIME with a
        // "not a constructor" TypeError; that is why only a non-DOT follower
        // is rejected here.
        //
        // Parenthesising escapes both rules: `new (import(''))` makes the call
        // a PrimaryExpression, hence a MemberExpression.
        //
        // test262 has no case either way. QuickJS matches this reading exactly
        // (it rejects `new import('').then` with "invalid use of 'import()'"
        // and accepts `new import.meta`). V8/node accept
        // `new import('').then`, which the grammar above does not derive, so
        // that leniency is deliberately not copied.
        if (self.check(TokenType.IMPORT)) {
            Token import_tok = self.advance()!;
            TokenType after_import = self.peek_type();
            self.lexer.pushback(import_tok);
            if (after_import != TokenType.DOT) {
                return self.fail("'import' call is not a valid constructor")~;
            }
        }
        // Parse the constructor (could be member access)
        ctor_reg = self.member_expr()!;

        // TypeScript constructor type arguments: `new Y<T>(...)`. The `<`
        // after the constructor name is type args only when followed by `(`;
        // otherwise it's a comparison.
        if (self.lexer.ts_mode && self.check(TokenType.LT) && self.ts_peek_generics_lparen()) {
            self.skip_generic_params()!;
        }

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
        ushort total_count_reg = REG_NONE;

        if (self.match(TokenType.LPAREN)) {
            if (!self.check(TokenType.RPAREN)) {
                for (;;) {
                    if (self.match(TokenType.ELLIPSIS)) {
                        // See compile_spread_source: the first spread eval is
                        // normal, later ones go into the region below first_arg.
                        bool is_first_spread = !has_spread;
                        if (!has_spread) {
                            has_spread = true;
                            // See begin_spread_args: relocate the ctor frame up
                            // and place the count register below first_arg so an
                            // unbounded spread cannot corrupt the argument slots.
                            total_count_reg = self.begin_spread_args(&ctor_reg, &first_arg, arg_count);
                            self.emit_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count);
                        }
                        ushort spread_reg = self.compile_spread_source(first_arg, arg_count, is_first_spread)!;
                        self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                        self.free_reg(spread_reg);
                    } else {
                        ushort arg_reg;
                        if (has_spread) {
                            // See emit_call: evaluate into the reserved
                            // below-first_arg region, outside the spread's
                            // runtime dest window, then PUTARG directly.
                            ushort saved_cap = self.reg_cap;
                            self.next_reg = self.spread_eval_base;
                            self.reg_cap = first_arg;
                            arg_reg = self.assignment_expr()!;
                            self.reg_cap = saved_cap;
                            self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                            self.free_reg(arg_reg);
                        } else {
                            arg_reg = self.assignment_expr()!;
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
                self.call_prop_obj_reg = REG_NONE;
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
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                self.call_prop_obj_reg = ctor_reg;
                ctor_reg = result;
            } else {
                // new X()?.prop
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);
                ushort prop_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)ctor_reg, (uint)prop_reg);
                self.free_reg(prop_reg);
                self.last_was_member = false;
                self.last_was_getvar = false;
                if (self.call_prop_obj_reg != REG_NONE) {
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
            if (self.check(TokenType.HASH_IDENT)) {
                // new X().#name, private field access on a freshly constructed
                // object. Resolves to a COMPILE_ERROR if no enclosing class
                // declares the name (e.g. eval("new C().#x") with no
                // PrivateEnvironment in scope); mirrors member_expr's DOT
                // branch in expressions.c3.
                Token priv_tok = self.advance()!;
                ushort priv_prop_reg = self.emit_private_access(priv_tok.str_value, ctor_reg)!;
                ushort priv_result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP_PRIVATE, (uint)priv_result, (uint)ctor_reg, (uint)priv_prop_reg);

                if (self.check(TokenType.LPAREN) || self.check(TokenType.OPT_CHAIN) || self.is_next_template()) {
                    self.free_reg(priv_prop_reg);
                    self.last_was_member = false;
                    self.call_prop_obj_reg = ctor_reg;
                } else {
                    self.last_was_member = true;
                    self.last_target_invalid = false;
                    self.last_member_is_super = false;
                    self.last_member_is_private = true;
                    self.last_member_obj_reg = ctor_reg;
                    self.last_member_prop_reg = priv_prop_reg;
                    self.call_prop_obj_reg = ctor_reg;
                }
                // priv_result is the freshly-allocated top register; priv_prop_reg
                // sits directly below it and stays live for postfix PUTPROP (same
                // reasoning as member_expr's DOT branch, free_reg is a no-op below
                // the top, and next_reg already == priv_result + 1 here).
                ctor_reg = priv_result;
                continue;
            }
            Token? prop_name_opt = self.lexer.next_token();
            if (catch err = prop_name_opt) return COMPILE_ERROR~;
            Token prop_name = prop_name_opt;
            char[] prop_str = prop_name.str_value;
            if (prop_str.len == 0) {
                prop_str = lexer::keyword_to_string(prop_name.type);
            }
            if (prop_name.type != TokenType.IDENTIFIER && prop_str.len == 0) {
                self.record_error("expected a property name after '.'");
                return COMPILE_ERROR~;
            }
            uint prop_const = self.add_string_constant(prop_str);
            ushort prop_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);
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
                self.last_target_invalid = false;
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
            // target (`new X()[k] += v`), see call_expr's LBRACKET branch
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
                self.last_target_invalid = false;
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
            self.call_prop_obj_reg = REG_NONE;
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
            // Member access (obj.prop), not a direct identifier reference,
            // so clear the direct eval flag.
            self.callee_is_eval = false;

            if (self.check(TokenType.HASH_IDENT)) {
                // obj.#name, private field access. `delete obj.#x` is a
                // SyntaxError (early error; not a runtime concern here).
                if (self.del_mode) {
                    return self.fail("Private fields can not be deleted")~;
                }
                Token priv_tok = self.advance()!;
                ushort prop_reg = self.emit_private_access(priv_tok.str_value, obj)!;

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP_PRIVATE, (uint)result, (uint)obj, (uint)prop_reg);

                self.last_was_member = true;
                self.last_target_invalid = false;
                self.last_member_is_super = false;
                self.last_member_is_private = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = prop_reg;
                self.last_member_obj_is_local = obj_is_base_local;

                if (self.lhs_mode) {
                    if (self.call_prop_obj_reg != REG_NONE) {
                        self.free_reg(self.call_prop_obj_reg);
                    }
                    self.call_prop_obj_reg = obj;
                } else {
                    TokenType priv_next_tt = self.peek_type();
                    bool priv_is_postfix = (priv_next_tt == TokenType.INC || priv_next_tt == TokenType.DEC);
                    if (!priv_is_postfix) {
                        self.free_reg(prop_reg);
                    }
                    if (self.call_prop_obj_reg != REG_NONE) {
                        self.free_reg(self.call_prop_obj_reg);
                    }
                    self.call_prop_obj_reg = priv_is_postfix ? REG_NONE : obj;
                }

                obj = result;
                obj_is_base_local = false;
                continue;
            }

            // Get next token, after '.' it can be an identifier OR any keyword
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
                self.record_error("expected a property name after '.'");
                return COMPILE_ERROR~;
            }
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);

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
            self.last_target_invalid = false;
            self.last_member_is_super = false;
            self.last_member_is_private = false;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = prop_reg;
            self.last_member_obj_is_local = obj_is_base_local;

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/prop alive for possible PUTPROP/DELPROP
                // Also set up for potential method call 'this'. Always save obj
                // for this-binding, it will be freed by assignment_expr cleanup
                // if no call follows, or consumed by emit_call/emit_tagged_template.
                TokenType next_tt = self.peek_type();
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != REG_NONE) {
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
                // a postfix INC/DEC, in that case postfix_expr needs prop alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free it.
                // Always save obj as call_prop_obj_reg for potential this-binding
                // (e.g. parenthesized expressions followed by a call).
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(prop_reg);
                }
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (is_postfix) {
                    // Postfix: keep obj alive for postfix_expr (via last_member_obj_reg)
                    self.call_prop_obj_reg = REG_NONE;
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
            // Computed member access, not a direct identifier reference.
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
            self.last_target_invalid = false;
            self.last_member_is_super = false;
            self.last_member_obj_reg = obj;
            self.last_member_prop_reg = idx_reg;
            self.last_member_obj_is_local = obj_is_base_local;

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/idx alive for possible PUTPROP/DELPROP
                // Always save obj for this-binding as well.
                TokenType next_tt2 = self.peek_type();
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (next_tt2 == TokenType.LPAREN || next_tt2 == TokenType.OPT_CHAIN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free idx_reg immediately, UNLESS the next token is
                // a postfix INC/DEC, in that case postfix_expr needs idx_reg alive
                // to emit PUTPROP after INC/DEC. postfix_expr will free it.
                // Always save obj as call_prop_obj_reg for potential this-binding.
                TokenType next_tt = self.peek_type();
                bool is_postfix = (next_tt == TokenType.INC || next_tt == TokenType.DEC);
                if (!is_postfix) {
                    self.free_reg(idx_reg);
                }
                // Free old call_prop_obj_reg before overwriting
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                if (is_postfix) {
                    self.call_prop_obj_reg = REG_NONE;
                } else {
                    self.call_prop_obj_reg = obj;
                }
            }
            obj = result;
            obj_is_base_local = false;
        } else if (self.is_next_template()) {
            // MemberExpression : MemberExpression TemplateLiteral, a tagged
            // template is itself a MemberExpression (distinct from a call
            // expression's `Arguments`), so `new tag\`...\`` evaluates the
            // tagged template first and applies `new` to its result.
            obj = self.emit_tagged_template(obj)!;
            if (self.call_prop_obj_reg != REG_NONE) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = REG_NONE;
            }
            self.last_was_member = false;
            obj_is_base_local = false;
        } else {
            break;
        }
    }

    return obj;
}

/// Compute the super base register for `super.x` / `super[x]` (§13.3.7.1
/// GetSuperBase): loads `__super__` (or `__static_super__` for static
/// methods, whose HomeObject is the constructor itself) and derives its
/// [[Prototype]]. When the binding already holds the HomeObject
/// (super_is_home_object, or any static method) that's a direct GETPROTO;
/// otherwise `__super__` holds the superclass constructor value itself
/// (the `extends Base` case), so the base is `Base.prototype` via GETPROP.
/// Returns the register holding the super base (caller owns/frees it).
fn ushort CompilerContext.emit_super_base(&self) {
    uint super_name_idx;
    if (self.super_is_static_method) {
        super_name_idx = self.static_super_name_idx;
        if (super_name_idx == 0xFFFFFFFF) {
            super_name_idx = self.add_string_constant("__static_super__");
        }
    } else {
        super_name_idx = self.super_name_idx;
        if (super_name_idx == 0xFFFFFFFF) {
            super_name_idx = self.add_string_constant("__super__");
        }
    }
    ushort super_ctor_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)super_ctor_reg, super_name_idx);
    ushort super_proto_reg;
    if (self.super_is_static_method || self.super_is_home_object) {
        super_proto_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROTO, (uint)super_proto_reg, (uint)super_ctor_reg, 0);
        self.free_reg(super_ctor_reg);
    } else {
        uint proto_name_idx = self.add_string_constant("prototype");
        ushort proto_key_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx);
        super_proto_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)super_proto_reg, (uint)super_ctor_reg, (uint)proto_key_reg);
        self.free_reg(proto_key_reg);
        self.free_reg(super_ctor_reg);
    }
    return super_proto_reg;
}

/// Parse primary expressions: literals, identifiers, grouping, etc.
fn ushort? CompilerContext.primary_expr(&self) {
    self.expr_depth++;
    defer self.expr_depth--;
    if (self.expr_depth > MAX_EXPR_DEPTH) {
        return self.fail("expression nested too deeply")~;
    }

    TokenType tt = self.peek_type();

    // A class heritage expression is a LeftHandSideExpression, so an arrow
    // function is not a legal head for it. Consume the flag here: only THIS
    // invocation is the outermost head, and every nested expression parsed
    // below (call arguments, parenthesised sub-expressions) recurses into a
    // fresh primary_expr that must accept arrows as usual.
    bool reject_arrow_head = self.no_arrow_head;
    self.no_arrow_head = false;

    // TypeScript generic arrow: `<T,>(params) => body`. Skip the type params
    // then fall through to the normal LPAREN arrow path. The legacy
    // angle-bracket type assertion `<T>expr` is rejected by
    // --erasableSyntaxOnly (TS1294), so anything that is not an arrow head
    // after the `<...>` group is a compile error rather than an accepted
    // expression.
    if (self.lexer.ts_mode && tt == TokenType.LT) {
        self.skip_generic_params()!;
        tt = self.peek_type();
        if (tt != TokenType.LPAREN) {
            return self.fail("type assertions must use 'as', not angle brackets (not erasable)")~;
        }
        // `<T>(...)` is a generic arrow only when `=>` directly follows the
        // group. Otherwise it is the legacy angle-bracket assertion
        // `<T>expr` (`<any>(10 + 10)`), rejected by --erasableSyntaxOnly.
        // Probe the paren group without consuming it.
        Lexer saved_lexer = *self.lexer;
        bool is_arrow = false;
        if (catch _e = self.advance()) {
            *self.lexer = saved_lexer;
        } else {
            int p = 1;
            while (p > 0) {
                TokenType t2 = self.peek_type();
                if (t2 == TokenType.EOF_TOKEN) break;
                Token? adv_opt = self.advance();
                if (catch _e2 = adv_opt) break;
                Token adv = adv_opt;
                if (adv.type == TokenType.LPAREN) { p++; }
                else if (adv.type == TokenType.RPAREN) { p--; }
            }
            is_arrow = self.check(TokenType.ARROW);
            if (!is_arrow) {
                // `(x: T): R => ...` — the return-type annotation sits
                // between the group and the arrow.
                if (catch _e3 = self.try_skip_ts_type_annotation()) {
                    *self.lexer = saved_lexer;
                    return self.fail("type assertions must use 'as', not angle brackets (not erasable)")~;
                }
                is_arrow = self.check(TokenType.ARROW);
            }
            *self.lexer = saved_lexer;
        }
        if (!is_arrow) {
            return self.fail("type assertions must use 'as', not angle brackets (not erasable)")~;
        }
    }

    switch (tt) {
        case TokenType.NUMBER:
            self.last_was_getvar = false;
            Token num_tok = self.advance()!;

            // ES2024 §12.9.3.1: both AnnexB decimal-integer forms that start
            // with `0` are Syntax Errors in strict-mode code, and this engine
            // is strict-only:
            //   LegacyOctalIntegerLiteral        `0` followed by 0-7 (`01`)
            //   NonOctalDecimalIntegerLiteral    `0` followed by 8-9 (`08`),
            //                                    and any digits after either
            // A `0` followed by ANY decimal digit is therefore one of the two,
            // so one test covers both — the previous 0-7 range accepted `08`
            // and `09` silently. `0x`/`0o`/`0b`/`0.`/`0e` are unaffected: the
            // second character is not a decimal digit.
            char[] nsrc = num_tok.str_value;
            if (nsrc.len >= 2 && nsrc[0] == '0' && nsrc[1] >= '0' && nsrc[1] <= '9') {
                return self.fail("a legacy octal or non-octal decimal literal is not allowed")~;
            }

            ushort num_reg = self.alloc_reg();

            // Check if it fits in a signed 16-bit immediate
            double val = num_tok.num_value;
            int int_val = (int)val;
            if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
                self.emit_a_sbx(Opcode.LDINT, (uint)num_reg, int_val);
            } else {
                uint const_idx = self.add_number_constant(val);
                self.emit_a_bc(Opcode.LDCONST, (uint)num_reg, const_idx);
            }
            return num_reg;

        case TokenType.BIGINT:
            self.last_was_getvar = false;
            Token bi_tok = self.advance()!;
            uint bi_idx = self.add_bigint_constant(bi_tok.str_value)!;
            ushort bi_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)bi_reg, bi_idx);
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
            self.emit_a_bc(Opcode.LDCONST, (uint)str_reg, str_idx);
            return str_reg;

        case TokenType.IDENTIFIER:
            // Check for arrow function: IDENTIFIER ARROW => single param
            {
                // Detect `async function ...` expression: consume the async
                // identifier and delegate to function_expr.
                if (self.peek_type() == TokenType.IDENTIFIER &&
                    self.match_async_function()) {
                    // match_async_function() has consumed `async` and token_start
                    // now points to its start. Save this for function_expr to use
                    // when retaining source text (ES2019 §19.2.3.5).
                    self.pending_async_function_src = self.lexer.token_start;
                    ushort r = self.function_expr(true)!;
                    self.pending_async_function_src = 0xFFFFFFFF;
                    return r;
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
                    // ClassHeritage is a LeftHandSideExpression: an async
                    // arrow is no more legal a head than a plain one.
                    if (reject_arrow_head) return COMPILE_ERROR~;
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

                // Check for literal keywords tokenized as identifiers.
                // `true`/`false`/`null` are ReservedWords, not contextual
                // keywords: an escaped spelling is NOT the literal AND is not
                // a usable identifier either (ES2024 §12.7.2 / §5.1.5), so
                // `true` is a SyntaxError rather than a variable read.
                if (id_tok.has_escape && (str_eq(id_tok.str_value, "true")
                        || str_eq(id_tok.str_value, "false")
                        || str_eq(id_tok.str_value, "null"))) {
                    return self.fail("keyword must not contain escaped characters")~;
                }
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
                // `undefined` is an ordinary identifier bound to a non-writable
                // global property (ES2015 §18.1.3), not a syntactic keyword like
                // true/false/null, it must fall through to normal identifier
                // resolution below so `undefined = 12` parses (AssignmentTargetType
                // simple) and throws TypeError at runtime rather than being
                // rejected as an early SyntaxError.

                // Arrow function: IDENTIFIER => ...
                if (!reject_arrow_head && self.check_arrow()) {
                    char[][1] params_arr;
                    params_arr[0] = id_tok.str_value;
                    // Capture byte offset of the IDENTIFIER (just consumed), the
                    // source for the arrow head runs from here to its body.
                    uint ident_arrow_src = self.lexer.token_start;
                    return self.parse_arrow_function(&params_arr[0], 1, false, ident_arrow_src)!;
                }

                // When the identifier is 'eval', track it for direct eval detection.
                // emit_call checks callee_is_eval to set has_direct_eval.
                // This must be set BEFORE the early return for local variables.
                self.callee_is_eval = str_eq(id_tok.str_value, "eval");

                // Try to resolve as a local variable first (skip at global scope, use environment)
                if (!self.is_global) {
                    if (try var_reg = self.resolve_var(id_tok.str_value)) {
                        self.last_was_getvar = false;
                        self.last_was_local_var = true;
                        self.last_local_var_reg = var_reg;
                        self.save_lhs_ident_name(id_tok.str_value);
                        return var_reg;
                    }
                }

                self.note_arguments_reference(id_tok.str_value)!;

                // Not found locally: emit GETVAR/GETGLOBAL to look up by name at runtime
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.last_getvar_code_pos = self.emit_ident_read((uint)id_reg, name_idx);
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
            // The compiler's own pushback stack is separate from the lexer's
            // buffers: the speculative scan's try_skip_ts_optional_marker /
            // try_skip_ts_type_annotation push rejected tokens onto it, so it
            // must be restored alongside the lexer or the grouping re-parse
            // reads a stale token first (e.g. `(t ? 1 : 2)` re-parsed as
            // starting at the `?`).
            uint saved_pb_count = self.pushback_count;
            Token[4] saved_pb_stack = self.pushback_stack;

            // Check for empty parens: () => ...
            if (self.check(TokenType.RPAREN)) {
                self.advance()!;  // consume ')'
                // TS: `() : T => ...` — skip return-type before ARROW.
                if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                if (!reject_arrow_head && self.check_arrow()) {
                    // No-param arrow: () => ...
                    // Restore lexer to right after '(', parse_arrow_function_reparse
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
                    self.pushback_count = saved_pb_count;
                    self.pushback_stack = saved_pb_stack;
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
                self.pushback_count = saved_pb_count;
                self.pushback_stack = saved_pb_stack;
                ushort inner2 = self.expression()!;
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                self.drop_paren_receiver_unless_ref();
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Flag the name rather than dropping it — parens
                // preserve AssignmentTargetType, so the saved name is still
                // needed for the `(eval) = 1` early error.
                //
                // The name only describes THIS expression when the group was a
                // bare identifier reference. Otherwise it is a leftover from
                // some inner operand (`(w = 2) * (w = 3)` leaves "w" behind),
                // so drop it: keeping it named an anonymous function "w".
                if (self.last_was_getvar || self.last_was_local_var) {
                    self.last_lhs_name_parenthesized = true;
                } else {
                    self.last_lhs_name_len = 0;
                }
                // A parenthesized arrow is a CoverParenthesizedExpression,
                // a PrimaryExpression, so it IS legal as a binary operand
                // (`"x" in (() => {})`). Clear the marker the inner arrow set;
                // the arrow-as-binary-operand check only targets bare arrows.
                self.last_was_arrow_expr = false;
                return inner2;
            }
            // Check for arrow with params: (id) => or (id, id, ...) => ...
            // `await` is a BindingIdentifier wherever it is not reserved
            // (§13.1.1), so `(await) => 1` is an arrow head in script code and
            // must enter this scan; await_is_identifier makes that decision.
            // This is only DETECTION — parse_arrow_function_reparse re-parses
            // the head through expect_binding_identifier, which re-applies the
            // reservation, so admitting the token here cannot accept anything
            // the real parse would reject.
            else if (self.peek_is_binding_identifier() || self.check(TokenType.ELLIPSIS)) {
                char[][8] param_names;
                ushort pc = 0;
                bool has_rest = false;
                bool is_arrow = false;

                for (;;) {
                    // Check for rest parameter
                    if (self.check(TokenType.ELLIPSIS)) {
                        self.advance()!;  // consume '...'
                        // `(...await) => 1` binds a rest param named "await"
                        // wherever the word is not reserved.
                        bool rest_is_ident = self.peek_is_binding_identifier();
                        Token t = self.advance()!;
                        if (!rest_is_ident) {
                            break;  // not a valid rest param, can't be arrow
                        }
                        param_names[pc++] = t.str_value;
                        has_rest = true;

                        // TS: rest param may carry a type annotation.
                        if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;

                        if (self.check(TokenType.RPAREN)) {
                            self.advance()!;  // consume ')'
                            // TS: skip return type annotation before ARROW.
                            if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                            if (self.check_arrow()) {
                                is_arrow = true;
                            }
                        }
                        break;
                    }

                    // A parameter may also be a destructuring pattern, e.g.
                    // (x, [b]) => ... or (x, {c} = {}) => ..., skip over it
                    // (handling nesting) rather than bailing, so mixed
                    // identifier/destructured param lists are still detected
                    // as arrow functions. The skipped pattern's bindings
                    // don't need to be tracked here: once `is_arrow` is
                    // confirmed, parse_arrow_function_reparse() re-parses
                    // the whole param list from source.
                    if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                        self.advance()!;
                        self.skip_destructure_pattern();
                        // TS: type annotation after destructure pattern.
                        if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                    } else {
                        // An unreserved `await` is a param name here too, so
                        // `(a, await) => 1` scans as an arrow head.
                        bool t_is_ident = self.peek_is_binding_identifier();
                        Token t = self.advance()!;
                        if (!t_is_ident) {
                            break;  // not a param name, can't be arrow
                        }
                        param_names[pc++] = t.str_value;
                        // TS: optional marker and type annotation on the param.
                        if (self.lexer.ts_mode) {
                            self.try_skip_ts_optional_marker()!;
                            self.try_skip_ts_type_annotation()!;
                        }
                    }

                    // Skip default value if present: = <expression>
                    if (self.check(TokenType.ASSIGN)) {
                        self.advance()!;  // consume '='
                        // Skip the default expression using the token scanner
                        self.skip_expression();
                    }

                    if (self.check(TokenType.RPAREN)) {
                        self.advance()!;  // consume ')'
                        // TS: return type annotation before ARROW.
                        if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                        if (self.check_arrow()) {
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
                        // TS: return type annotation before ARROW.
                        if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                        if (self.check_arrow()) {
                            is_arrow = true;
                        }
                        break;
                    }
                }

                if (is_arrow && reject_arrow_head) {
                    // `class C extends (a, b) => {}`: the speculative scan
                    // confirmed an arrow, but ClassHeritage is a
                    // LeftHandSideExpression and admits none.
                    return COMPILE_ERROR~;
                }
                if (is_arrow) {
                    // Restore lexer to right after '(', compile_arrow_inner
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
                    self.pushback_count = saved_pb_count;
                    self.pushback_stack = saved_pb_stack;
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
                self.pushback_count = saved_pb_count;
                self.pushback_stack = saved_pb_stack;
                ushort inner2 = self.expression()!;
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                self.drop_paren_receiver_unless_ref();
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Flag the name rather than dropping it — parens
                // preserve AssignmentTargetType, so the saved name is still
                // needed for the `(eval) = 1` early error.
                //
                // The name only describes THIS expression when the group was a
                // bare identifier reference. Otherwise it is a leftover from
                // some inner operand (`(w = 2) * (w = 3)` leaves "w" behind),
                // so drop it: keeping it named an anonymous function "w".
                if (self.last_was_getvar || self.last_was_local_var) {
                    self.last_lhs_name_parenthesized = true;
                } else {
                    self.last_lhs_name_len = 0;
                }
                // A parenthesized arrow is a CoverParenthesizedExpression,
                // a PrimaryExpression, so it IS legal as a binary operand
                // (`"x" in (() => {})`). Clear the marker the inner arrow set;
                // the arrow-as-binary-operand check only targets bare arrows.
                self.last_was_arrow_expr = false;
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
                self.pushback_count = saved_pb_count;
                self.pushback_stack = saved_pb_stack;
                ushort inner2 = self.expression()!;
                // A parenthesized expression is never a bare IdentifierReference,
                // so `(eval)(...)`/`(0, eval)(...)` must NOT be treated as direct
                // eval even though the innermost operand's name is "eval" (ES2015
                // §12.3.4.1 step 3: IsIdentifierRef must hold syntactically).
                self.callee_is_eval = false;
                self.expect(TokenType.RPAREN)!;
                self.drop_paren_receiver_unless_ref();
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Flag the name rather than dropping it — parens
                // preserve AssignmentTargetType, so the saved name is still
                // needed for the `(eval) = 1` early error.
                //
                // The name only describes THIS expression when the group was a
                // bare identifier reference. Otherwise it is a leftover from
                // some inner operand (`(w = 2) * (w = 3)` leaves "w" behind),
                // so drop it: keeping it named an anonymous function "w".
                if (self.last_was_getvar || self.last_was_local_var) {
                    self.last_lhs_name_parenthesized = true;
                } else {
                    self.last_lhs_name_len = 0;
                }
                // A parenthesized arrow is a CoverParenthesizedExpression,
                // a PrimaryExpression, so it IS legal as a binary operand
                // (`"x" in (() => {})`). Clear the marker the inner arrow set;
                // the arrow-as-binary-operand check only targets bare arrows.
                self.last_was_arrow_expr = false;
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
                self.drop_paren_receiver_unless_ref();
                self.inside_parens = saved_inside_parens;
                // A parenthesized identifier is not an IdentifierRef for
                // NamedEvaluation purposes (ES2015 §12.15.4 step 1.c uses
                // static IsIdentifierRef, which CoverParenthesizedExpression
                // never satisfies): `(fn) = function(){}` must NOT name the
                // function. Flag the name rather than dropping it — parens
                // preserve AssignmentTargetType, so the saved name is still
                // needed for the `(eval) = 1` early error.
                //
                // The name only describes THIS expression when the group was a
                // bare identifier reference. Otherwise it is a leftover from
                // some inner operand (`(w = 2) * (w = 3)` leaves "w" behind),
                // so drop it: keeping it named an anonymous function "w".
                if (self.last_was_getvar || self.last_was_local_var) {
                    self.last_lhs_name_parenthesized = true;
                } else {
                    self.last_lhs_name_len = 0;
                }
                // A parenthesized arrow is a CoverParenthesizedExpression,
                // a PrimaryExpression, so it IS legal as a binary operand
                // (`"x" in (() => {})`). Clear the marker the inner arrow set;
                // the arrow-as-binary-operand check only targets bare arrows.
                self.last_was_arrow_expr = false;
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
            if (!self.is_user_generator) {
                // `yield` is reserved in all strict-mode code (ES2024
                // §13.1.1) and this engine is strict-only, so outside a
                // generator it is never an IdentifierReference: it can only
                // be the start of a YieldExpression, which is not available
                // here. Either way a SyntaxError.
                //
                // The gate is is_user_generator, not is_generator: a plain
                // async function body is compiled as a coroutine and so has
                // is_generator set, but it is not a GeneratorBody and its
                // grammar is [~Yield]. Testing is_generator here let `yield`
                // through as a bare IdentifierReference in every async
                // function (`async function f(){ x[yield]; }`).
                return self.fail("'yield' is a reserved word")~;
            }
            // Even inside a generator, a YieldExpression is a Syntax Error in
            // the FormalParameters (ES2015 §14.1.2 / §15.5.1: "It is a Syntax
            // Error if FormalParameters Contains YieldExpression"). The default
            // thunk for a generator param sets forbid_yield to mark that the
            // enclosing YieldExpression production is not available here, even
            // though is_generator is propagated so `yield` stays a reserved
            // word rather than an identifier.
            if (self.forbid_yield) {
                return COMPILE_ERROR~;
            }
            // A YieldExpression is an AssignmentExpression (§13.15) and
            // derives from nothing tighter, so it is only legal where the
            // grammar expects an AssignmentExpression. assignment_expr marks
            // that position; a `yield` reached as a unary operand or as a
            // non-leftmost binary operand (`!yield`, `1 + yield`) has had the
            // mark cleared on the way down and is a SyntaxError.
            if (!self.yield_ok_here) {
                return self.fail("'yield' is only allowed where an AssignmentExpression is expected")~;
            }
            self.advance()!;  // consume 'yield'
            // ES2015 §14.4 YieldExpression: `yield [no LineTerminator here] *`
            // and `yield [no LineTerminator here] AssignmentExpression`, a
            // LineTerminator right after `yield` forces the bare `yield`
            // (yields undefined), same as ASI restricted productions.
            // `seen_line_term` reflects whitespace scanned *before* the most
            // recently produced token, so force the lookahead scan (via
            // peek_type) before reading it, otherwise it's stale from
            // before `yield` itself (see postfix_expr's nl_before_postfix_op
            // for the same pattern).
            self.peek_type();
            bool nl_after_yield = self.lexer.seen_line_term;
            // Check for yield* (delegating yield)
            bool is_delegate = false;
            if (!nl_after_yield && self.match(TokenType.STAR)) {
                is_delegate = true;
            }

            // Both YieldExpression operand forms are `AssignmentExpression
            // [?In]`, so both inherit the enclosing In parameter. Captured
            // once here, before either branch parses its operand.
            bool yield_no_in = self.yield_forbid_in;

            ushort val_reg;
            if (is_delegate) {
                self.forbid_in = yield_no_in;
                ushort iterable_reg = self.assignment_expr()!;
                self.forbid_in = false;
                if (self.is_async_gen()) {
                    // async `yield* EXPR` (ES2018 §14.4.14 async / §27.6.3.8):
                    // delegate over the *async* iterator protocol. GET_ITER_ASYNC
                    // does GetIterator(EXPR, async), preferring @@asyncIterator
                    // and wrapping a sync source in %AsyncFromSyncIterator%. The
                    // YIELD_STAR_ASYNC opcode is then a resumable state machine
                    // that Awaits every inner next/throw/return result, Awaits
                    // each yielded value (AsyncGeneratorYield), and forwards the
                    // consumer's throw/return completions to the delegate.
                    ushort iter_reg = self.alloc_reg();
                    self.emit_abc(Opcode.GET_ITER_ASYNC, (uint)iter_reg, (uint)iterable_reg, 0);
                    self.free_reg(iterable_reg);
                    ushort result_reg = self.alloc_reg();
                    self.emit_abc(Opcode.YIELD_STAR_ASYNC, (uint)result_reg, (uint)iter_reg, 0);
                    self.free_reg(iter_reg);
                    return result_reg;
                }
                // yield* iterable, delegate to the inner iterable via the ES6 iterator protocol.
                // The YIELD_STAR opcode handles Getting the iterator, calling .next() in a
                // suspend/resume loop, and properly delegating .throw()/.return().
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
                    // Mark a newline-terminated bare `yield` so binary_expr
                    // refuses to extend it with an operator (see the field
                    // doc on last_was_newline_yield).
                    self.last_was_newline_yield = nl_after_yield;
                    return result;
                }
                // `yield [no LineTerminator here] AssignmentExpression[?In]`:
                // the operand inherits the enclosing In parameter, so in a
                // `[~In]` position (a for-init) the operand may not consume an
                // `in` either. Without this, `for (yield '' in {}; ; ) ;`
                // parsed, where the spec and every other engine report a
                // SyntaxError. binary_expr already consumed forbid_in on the
                // way down, so restore it from the parked copy.
                self.forbid_in = yield_no_in;
                val_reg = self.assignment_expr()!;
                self.forbid_in = false;
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)result, (uint)val_reg, 0);
                // ES2018 §27.6.3.8 AsyncGeneratorYield step 5: the yield operand
                // is awaited before the request settles. Emit AWAIT here so a
                // yielded thenable resolves to its value.
                if (self.is_async_gen()) {
                    self.emit_abc(Opcode.AWAIT, (uint)result, 0, 0);
                    self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                }
                self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
                self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                self.free_reg(val_reg);
                return result;
            }
        }

        // `await expr`, contextual keyword, only valid in async functions.
        // Emits AWAIT + LOAD_RESUME so the VM can suspend/resume at this point.
        // In script (non-module) code, `await` is just an IdentifierName per
        // ES2024 §13.1.1, only the operator in async functions. Outside of
        // an async function (and outside a module) `await` is an identifier,
        // so handle it via the standard identifier-as-expression path:
        // resolve as a local variable if possible, else emit GETVAR.
        case TokenType.AWAIT:
        {
            if (!self.is_async) {
                // In a module, `await` is always reserved (ES2024 §13.1.1),
                // it is never a plain IdentifierName, even outside an async
                // function. Reject rather than treating it as an identifier.
                // A class static block's own statement list is likewise
                // always [+Await] (ES2022 §15.7.11) regardless of whether it
                // is lexically nested inside an async function.
                if (self.is_module || self.forbid_await) {
                    return COMPILE_ERROR~;
                }
                // IdentifierReference (or an arrow's single parameter) rather
                // than the AwaitExpression terminal, so an escaped spelling is
                // a plain name here. The [+Await] branch below keeps rejecting
                // it, where `await` really is the terminal.
                Token id_tok = self.advance(true)!;
                if (!reject_arrow_head && self.check_arrow()) {
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
                self.note_arguments_reference(id_tok.str_value)!;
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.last_getvar_code_pos = self.emit_ident_read((uint)id_reg, name_idx);
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                self.save_lhs_ident_name(id_tok.str_value);
                return id_reg;
            }
            // Even inside an async function, an AwaitExpression is a Syntax
            // Error in the FormalParameters (ES2017 §14.7 / CreateDynamicFunction
            // step: "If parameters Contains AwaitExpression is true, throw a
            // SyntaxError"). The default thunk for an async param sets
            // forbid_await to mark that the AwaitExpression production is not
            // available here, even though is_async is propagated so `await`
            // stays reserved rather than an identifier.
            if (self.forbid_await) {
                return COMPILE_ERROR~;
            }
            self.advance()!;  // consume 'await'
            ushort operand = self.unary_expr()!;
            // AWAIT suspends the async function; LOAD_RESUME loads the settled value
            self.emit_abc(Opcode.AWAIT, (uint)operand, 0, 0);
            self.emit_abc(Opcode.LOAD_RESUME, (uint)operand, 0, 0);
            return operand;
        }

        // `import(...)`, dynamic import expression (ES2020), or the
        // `import.meta` meta-property (ES2024 §13.3.12).
        case TokenType.IMPORT:
        {
            Token import_tok = self.advance()!;  // consume 'import'

            // `import.meta` (MetaProperty). Valid ONLY in module code; in a
            // Script, direct/indirect eval, or a Function/Generator/Async
            // body it is an early SyntaxError (compile_eval never sets
            // is_module). The terminal words `import` and `meta` must appear
            // literally, a Unicode escape in either is a SyntaxError.
            if (self.check(TokenType.DOT)) {
                if (!self.module_goal) {
                    return self.fail("import.meta is only valid in a module")~;
                }
                if (import_tok.has_escape) {
                    return self.fail("'import' in import.meta must not contain escape sequences")~;
                }
                self.advance()!;  // consume '.'
                Token meta_tok = self.advance()!;
                char[] meta_name = meta_tok.str_value;
                if (meta_name.len == 0) {
                    meta_name = lexer::keyword_to_string(meta_tok.type);
                }
                if (!(meta_name.len == 4 && meta_name[0] == 'm' && meta_name[1] == 'e'
                      && meta_name[2] == 't' && meta_name[3] == 'a')) {
                    return self.fail("expected 'meta' after 'import.'")~;
                }
                if (meta_tok.has_escape) {
                    return self.fail("'meta' in import.meta must not contain escape sequences")~;
                }
                ushort meta_reg = self.alloc_reg();
                self.emit_abc(Opcode.IMPORT_META, (uint)meta_reg, 0, 0);
                // import.meta is a MemberExpression but not a
                // SimpleAssignmentTarget (AssignmentTargetType is invalid):
                // clear the flags so `import.meta = v`, `import.meta++`, and
                // destructuring targets are rejected like `f()`.
                self.last_was_member = false;
                self.last_was_getvar = false;
                return meta_reg;
            }

            if (!self.match(TokenType.LPAREN)) {
                return self.fail("'import' as an expression must be followed by '(' (dynamic import)")~;
            }
            // Materialize the specifier into a fresh temp immediately. A bare
            // `import(x = a)` returns a live local's register (assignment_expr
            // aliases the RHS local), so freeing that register and reusing it
            // for `result` would clobber the local. Copying into a dedicated
            // temp isolates the DYN_IMPORT operands from any live binding.
            ushort spec_raw = self.assignment_expr()!;
            ushort spec_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)spec_reg, (uint)spec_raw, 0);
            self.free_reg(spec_raw);
            // Optional second argument: import(specifier, options). Per ES2025
            // §13.3.10 the options AssignmentExpression IS evaluated (it may
            // have side effects) and its `with`/import-attributes are validated
            // at runtime; validation failures reject the returned promise. When
            // no second argument is present, pass `undefined` (no attributes).
            ushort options_reg = self.alloc_reg();
            bool have_options = false;
            if (self.match(TokenType.COMMA)) {
                if (!self.check(TokenType.RPAREN)) {
                    ushort opt = self.assignment_expr()!;
                    self.emit_abc(Opcode.LDREG, (uint)options_reg, (uint)opt, 0);
                    self.free_reg(opt);
                    have_options = true;
                    // Allow a further trailing comma: import(x, opts,)
                    self.match(TokenType.COMMA);
                }
            }
            if (!have_options) {
                self.emit_abc(Opcode.LDUNDEF, (uint)options_reg, 0, 0);
            }
            self.expect(TokenType.RPAREN)!;
            // Read order at runtime: A (result) may reuse spec_reg's slot, so
            // the opcode reads B (spec) and C (options) before writing A. Both
            // spec_reg and options_reg are private temps, so nothing live is
            // clobbered even when result aliases spec_reg.
            self.free_reg(options_reg);
            self.free_reg(spec_reg);
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.DYN_IMPORT, (uint)result, (uint)spec_reg, (uint)options_reg);
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
            // super(), call superclass constructor
            if (self.match(TokenType.LPAREN)) {
                // Look up __super__ from the environment
                if (!self.has_super_binding) {
                    return COMPILE_ERROR~;  // super() only valid with extends
                }
                // super() only valid in constructors, not in methods/getters/setters
                if (!self.is_constructable) {
                    return COMPILE_ERROR~;
                }
                uint super_name_idx = self.super_name_idx;
                if (super_name_idx == 0xFFFFFFFF) {
                    // Fallback for contexts that haven't set super_name_idx
                    // (e.g. object literal methods): use the generic name.
                    super_name_idx = self.add_string_constant("__super__");
                }
                ushort super_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.GETVAR, (uint)super_reg, super_name_idx);

                // Parse arguments
                ushort first_arg = super_reg + 2;
                if (self.next_reg < first_arg) {
                    self.next_reg = first_arg;
                }
                ushort arg_count = 0;
                bool has_spread = false;
                ushort total_count_reg = REG_NONE;
                if (!self.check(TokenType.RPAREN)) {
                    for (;;) {
                        // Spread argument: super(...iterable), same lowering
                        // as emit_call (SPREAD_ARG + runtime count register).
                        if (self.match(TokenType.ELLIPSIS)) {
                            // See compile_spread_source: the first spread eval
                            // is normal, later ones go into the region below
                            // first_arg.
                            bool is_first_spread = !has_spread;
                            if (!has_spread) {
                                has_spread = true;
                                // See begin_spread_args: relocate the super frame
                                // up and place the count register below first_arg
                                // so an unbounded spread cannot corrupt the args.
                                total_count_reg = self.begin_spread_args(&super_reg, &first_arg, arg_count);
                                self.emit_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count);
                            }
                            ushort spread_reg = self.compile_spread_source(first_arg, arg_count, is_first_spread)!;
                            self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)total_count_reg, (uint)spread_reg);
                            self.free_reg(spread_reg);
                        } else {
                            ushort arg_reg;
                            if (has_spread) {
                                // See emit_call: evaluate into the reserved
                                // below-first_arg region, outside the spread's
                                // runtime dest window, then PUTARG directly.
                                ushort saved_cap = self.reg_cap;
                                self.next_reg = self.spread_eval_base;
                                self.reg_cap = first_arg;
                                arg_reg = self.assignment_expr()!;
                                self.reg_cap = saved_cap;
                                self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)total_count_reg, (uint)arg_reg);
                                self.free_reg(arg_reg);
                            } else {
                                arg_reg = self.assignment_expr()!;
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

                // Place 'this' slot, use LDUNDEF as a placeholder; SUPER_CALL
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

            // super.property, access property on superclass prototype
            // super[expr], computed property access on superclass prototype
            if (self.check(TokenType.DOT) || self.check(TokenType.LBRACKET)) {
                // super.x / super[x] is syntactically valid in any class method or
                // object-literal method, even without `extends`. The runtime raises
                // a ReferenceError/TypeError when GetSuperBase returns undefined/null.
                if (!self.has_super_binding && !self.in_class_body && !self.super_is_home_object) {
                    self.record_error("'super' is only valid in a class method, object method, or class body");
                    return COMPILE_ERROR~;
                }

                // `delete super.x` / `delete super[x]`, ES2022 §13.5.1.2 step 5.b
                // (and the test262 super-property-* tests): the IsSuperReference
                // check throws ReferenceError for ANY delete of a super property,
                // regardless of the super base's value. This check must run BEFORE
                // ToPropertyKey (for super[expr]) and BEFORE RequireObjectCoercible
                // on the super base (for super.x with null/undefined base). Emit
                // THROW_REF upfront; the rest of the super-resolution parsing
                // produces unreachable dead code that the runtime never executes.
                if (self.del_mode) {
                    uint msg_idx = self.add_string_constant("Cannot delete a super property");
                    ushort throw_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.THROW_REF, (uint)throw_reg, msg_idx);
                    // Consume the property-name / computed-key tokens so the
                    // surrounding parser sees a clean state. We still parse
                    // `super[expr]` correctly for syntax errors, but the emitted
                    // bytecode is dead code (unreachable after THROW_REF).
                    if (self.match(TokenType.DOT)) {
                        // `super.#x` is not a SuperProperty (see below), so the
                        // grammar error outranks the delete ReferenceError.
                        if (self.check(TokenType.HASH_IDENT)) return COMPILE_ERROR~;
                        char[] prop_str = self.read_property_name()!;
                    } else if (self.match(TokenType.LBRACKET)) {
                        // Save register state, the inner expression's emitted
                        // code is unreachable, so its register allocations
                        // must not leak into the surrounding scope.
                        ushort saved_next_reg = self.next_reg;
                        ushort saved_max_reg = self.max_reg;
                        self.expression()!;
                        self.expect(TokenType.RBRACKET)!;
                        self.next_reg = saved_next_reg;
                        self.max_reg = saved_max_reg;
                    }
                    // Reset the member/getvar tracking so the enclosing DELETE
                    // handler doesn't double-emit THROW_REF or try to patch a
                    // non-existent GETPROP into DELPROP.
                    self.last_was_member = false;
                    self.last_was_getvar = false;
                    self.last_member_is_super = false;
                    self.last_member_obj_reg = 0;
                    self.last_member_prop_reg = 0;
                    self.last_member_is_private = false;
                    self.last_was_local_var = false;
                    self.last_was_optional_chain = false;
                    self.call_prop_obj_reg = REG_NONE;
                    return throw_reg;
                }

                // Helper macro-inline: compute super base into super_proto_reg.
                // Defined here so both DOT and LBRACKET branches can call it after
                // key evaluation (important for super[expr]: key must be evaluated
                // BEFORE GetSuperBase per §13.5.3 Runtime Semantics).
                ushort super_proto_reg = REG_NONE;

                // For super.x (DOT), the key is compile-time constant so we can
                // compute the super base first (no observable ordering difference).
                // For super[expr] (LBRACKET), the spec requires evaluating the key
                // expression before checking/accessing the super base.
                ushort result;
                ushort super_key_reg;
                if (self.match(TokenType.DOT)) {
                    // ES2022 §13.3.7 SuperProperty accepts only
                    // `super.IdentifierName` / `super[Expression]`, a PrivateName
                    // is not an IdentifierName, so `super.#x` is an early
                    // SyntaxError rather than a private-field access.
                    if (self.check(TokenType.HASH_IDENT)) {
                        self.record_error("'super.#x' is not allowed, a super property must be a public name");
                        return COMPILE_ERROR~;
                    }
                    // DOT: compute super base first, then emit constant key.
                    super_proto_reg = self.emit_super_base();
                    char[] prop_str = self.read_property_name()!;
                    uint prop_idx = self.add_string_constant(prop_str);
                    super_key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)super_key_reg, prop_idx);
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP_SUPER, (uint)result, (uint)super_proto_reg, (uint)super_key_reg);
                } else {
                    // LBRACKET: §13.3.7.1 step 2 requires GetThisBinding() BEFORE
                    // evaluating the key expression, in a derived constructor
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
                    // Now compute super base (§13.3.7.1 GetSuperBase).
                    super_proto_reg = self.emit_super_base();
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP_SUPER, (uint)result, (uint)super_proto_reg, (uint)super_key_reg);
                }

                self.last_was_member = true;
                self.last_target_invalid = false;
                self.last_member_obj_reg = super_proto_reg;
                self.last_member_prop_reg = super_key_reg;
                self.last_member_is_super = true;

                // For super method calls (super.m() / super[s]()), the this-binding
                // must be the current instance, not the prototype. Emit LDTHIS into a
                // fresh register and store it in call_prop_obj_reg so emit_call picks
                // it up. call_expr will free the register if no call follows.
                if (self.call_prop_obj_reg != REG_NONE) {
                    self.free_reg(self.call_prop_obj_reg);
                }
                ushort this_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDTHIS, (uint)this_reg, 0, 0);
                self.call_prop_obj_reg = this_reg;

                return result;
            }

            self.record_error("'super' must be followed by a method call, property, or computed key");
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
            self.emit_a_bc(Opcode.LDCONST, (uint)result_reg, head_idx);

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
            // converted via ToString directly, unlike the `+` operator,
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
                self.emit_a_bc(Opcode.LDCONST, (uint)mid_reg, mid_idx);

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
            self.emit_a_bc(Opcode.LDCONST, (uint)tail_reg, tail_idx);

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
            self.emit_a_bc(Opcode.LDCONST, (uint)tmpl_reg, tmpl_idx);
            return tmpl_reg;

        case TokenType.REGEXP: {
            Token re_tok = self.advance()!;
            self.validate_regexp_literal(re_tok.str_value)!;
            uint re_idx = self.add_string_constant(re_tok.str_value);
            ushort re_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.NEWREGEXP, (uint)re_reg, re_idx);
            return re_reg;
        }

        // `new MemberExpression`, e.g. `new Foo()`, `new new RegExp`.
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
                self.emit_ident_read((uint)let_reg, name_idx);
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
/// syntax error, not a valid empty expression, silently emitting `undefined`
/// here previously masked things like a lone `++`/`+` at end of input.
fn ushort? CompilerContext.literal_keyword(&self) {
    return self.fail("unexpected token in expression")~;
}

/// Parse-time validation of a regexp literal (ES §12.9.3 early errors):
/// the pattern must compile under the literal's flags. `str_value` is the
/// raw "/pattern/flags" text. Splitting mirrors the VM's NEWREGEXP handler.
/// Flags must be valid, non-duplicate, and u/v mutually exclusive.
fn void? CompilerContext.validate_regexp_literal(&self, char[] raw) {
    usz len = raw.len;
    if (len < 2 || raw[0] != '/') return;

    usz end_slash = len - 1;
    while (end_slash > 0 &&
           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
        end_slash--;
    }
    if (end_slash == 0 || raw[end_slash] != '/') return;

    char[] pattern_data = raw[1..end_slash - 1];
    char[] flag_data = {};
    if (end_slash + 1 < len) {
        flag_data = raw[end_slash + 1..len - 1];
    }

    int flags = 0;
    uint seen = 0;
    foreach (f : flag_data) {
        uint bit;
        switch (f) {
            case 'g': bit = 1;
            case 'i': bit = 2;    flags |= re_bindings::RE_FLAG_IGNORECASE;
            case 'm': bit = 4;    flags |= re_bindings::RE_FLAG_MULTILINE;
            case 's': bit = 8;    flags |= re_bindings::RE_FLAG_DOTALL;
            case 'u': bit = 16;   flags |= re_bindings::RE_FLAG_UNICODE;
            case 'y': bit = 32;   flags |= re_bindings::RE_FLAG_STICKY;
            case 'd': bit = 64;   flags |= re_bindings::RE_FLAG_INDICES;
            case 'v': bit = 128;  flags |= re_bindings::RE_FLAG_UNICODE_SETS;
            default:
                return self.fail("invalid regexp flag")~;
        }
        if ((seen & bit) != 0) {
            return self.fail("duplicate regexp flag")~;
        }
        seen |= bit;
    }
    if ((seen & 16) != 0 && (seen & 128) != 0) {
        return self.fail("regexp flags u and v are mutually exclusive")~;
    }

    // The runtime NEWREGEXP compiles the INTERNED pattern, which str_intern
    // normalizes to CESU-8 (astral chars become surrogate pairs). Validate
    // the same bytes, or astral literals get rejected here that the runtime
    // accepts. CESU-8 output is at most 1.5x the UTF-8 input.
    usz plen = pattern_data.len;
    char* buf = (char*)alloc::malloc_try(mem, (sz)(plen * 2 + 1)) ?? null;
    if (buf == null) return;
    defer mem::free(buf);
    if (hstring::has_raw_utf8_astral(pattern_data)) {
        plen = (usz)hstring::normalize_to_cesu8(pattern_data, buf[0..plen * 2]);
    } else {
        mem::copy(buf, pattern_data.ptr, (sz)(plen));
    }
    buf[plen] = 0;
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(buf, plen, flags, &error_buf, 128);
    if (compiled == null) {
        return self.fail("invalid regular expression")~;
    }
    re_bindings::re_free(compiled);
}

/// Parse object literal: { key: value, ... }
fn ushort? CompilerContext.object_literal(&self) {
    // An object literal is not an AnonymousFunctionDefinition, any pending
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
    // first concise method / accessor, plain data literals skip it entirely
    // (large array-of-literal initialisers would otherwise exhaust registers).
    bool super_bound = false;

    // ES2015 §12.2.6.1 Early Errors: it is a SyntaxError for a literal to
    // contain more than one `__proto__: value` property. Only that form counts
    //, shorthand, methods, accessors and computed keys are all exempt (they
    // define an ordinary own property rather than setting [[Prototype]]).
    // A local is exactly the right scope: nested literals recurse into their
    // own call and so track their own count.
    bool seen_proto_key = false;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            if (self.check(TokenType.RBRACE)) {
                break;
            }

            // ES2015 §14.3: generator-method shorthand, `*m() { yield ... }`.
            // Save the generator + async flags; they are only overridden right
            // before compiling the method body below. Property keys, computed
            // keys, spread expressions, and `key: value` expressions are all
            // evaluated in the *enclosing* function's context (e.g. `...yield`
            // inside a generator body must still see is_generator = true), so
            // we must not clear the flags here.
            bool saved_is_generator = self.is_generator;
            bool saved_is_user_generator = self.is_user_generator;
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
            // ES2017 §14.6: async-method shorthand, `{ async m() {} }`.
            // `async` is not a keyword; match_async_method_prefix consumes it
            // only when it is a modifier (followed on the same line by a
            // method-name token), so `{ async: 1 }`, `{ async }`, and
            // `{ async() {} }` all keep their existing meaning.
            bool is_async_method = self.match_async_method_prefix();
            bool is_generator_method = self.match(TokenType.STAR);

            // Parse property key
            ushort key_reg;
            uint shorthand_name_idx = 0;  // 0 = not a shorthand-eligible key
            char[] shorthand_name = {};   // identifier text, for local-var resolution
            bool is_shorthand_key = false;  // true iff the key came from a plain identifier
            bool is_computed_key = false;  // true iff the key came from `[expr]`
            // Source start for Function.prototype.toString retention. Captured
            // above (prop_src_start) at the property's first token, which is the
            // correct span origin for all method forms, `async`/`*` prefixes,
            // `get`/`set`, and identifier/string/number/computed keys alike.
            uint key_src_start = prop_src_start;

            TokenType key_tt = self.peek_type();
            if (key_tt == TokenType.IDENTIFIER || key_tt == TokenType.STRING
                || lexer::keyword_to_string(key_tt).len > 0) {
                // A PropertyName is an IdentifierName, so an escaped reserved
                // word is a legal key (`({ break: 1 })`).
                Token key_tok = self.advance(true)!;
                // ES2015 §12.2.6.8: shorthand is only legal for a plain
                // IdentifierReference, string-literal keys and reserved
                // words used as keys must not be treated as shorthand.
                // `true` / `false` / `null` lex as plain IDENTIFIER tokens in
                // this lexer (resolved to literals by string comparison at
                // the primary-expression level) but are reserved words per
                // spec and cannot be used as an IdentifierReference.
                // `{ await }` / `{ yield }` shorthand is a valid
                // IdentifierReference where the context permits the keyword as
                // an identifier, outside a module/async fn for `await`, outside
                // a generator for `yield` (a class static block's forbid flags
                // reset in a nested non-async function/arrow, so this is how the
                // static-init-await object-shorthand test compiles). The keyword
                // token's str_value already carries the name for resolve_var.
                is_shorthand_key = (key_tt == TokenType.IDENTIFIER
                        && !str_eq(key_tok.str_value, "true")
                        && !str_eq(key_tok.str_value, "false")
                        && !str_eq(key_tok.str_value, "null"))
                    || (key_tt == TokenType.AWAIT && !self.is_module && !self.is_async && !self.forbid_await);
                // `yield` is absent: it is reserved in all strict code, so
                // `{ yield }` shorthand is a SyntaxError. `{ yield: v }` and
                // `{ yield(){} }` use the property-name path, not this one.

                // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
                // Generator-method shorthand forbids the getter/setter shape, `*get` / `*set`
                // would otherwise be misparsed as a method shorthand that named `get`/`set`,
                // so we disable the detection entirely when a star was consumed.
                bool is_obj_getter = false;
                bool is_obj_setter = false;
                // `get`/`set` opens an accessor only when the NEXT token can
                // actually start a PropertyName. Excluding just `:` and `(`
                // left every other shorthand form (`{ get, set }`, `{ get }`,
                // `{ get = d }`) misparsed as an accessor with a missing name.
                // Same positive predicate the class body uses (class.c3's
                // next_starts_key), minus HASH_IDENT: private names are class
                // elements only.
                bool next_starts_key = self.check(TokenType.IDENTIFIER)
                    || self.check(TokenType.STRING)
                    || self.check(TokenType.NUMBER)
                    || self.check(TokenType.BIGINT)
                    || self.check(TokenType.LBRACKET)
                    || lexer::keyword_to_string(self.peek_type()).len > 0;
                // Escaped `get`/`set` (`get m(){}`) is a plain
                // IdentifierName, never the contextual accessor keyword
                // (ES2024 §5.1.5), so it does not open an accessor. It then
                // fails as `get m(){}` — two names with no separator — which
                // is the SyntaxError the spec requires.
                if (!is_generator_method && key_tt == TokenType.IDENTIFIER && !key_tok.has_escape
                        && next_starts_key) {
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
                    // per ES2017 §14.6, the async modifier only combines with
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
                        // evaluating the computed key, coerce in place now
                        // (see the matching comment in the data-property
                        // computed-key branch below) so an abrupt completion
                        // (e.g. Object.create(null) with no toString/valueOf)
                        // throws here rather than being silently accepted.
                        self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
                    } else {
                        Token prop_tok;
                        if (prop_tt == TokenType.IDENTIFIER || prop_tt == TokenType.STRING
                            || lexer::keyword_to_string(prop_tt).len > 0) {
                            // An accessor's PropertyName is an IdentifierName
                            // like a plain key, so `({ get break(){} })`
                            // names the accessor rather than being rejected.
                            prop_tok = self.advance(true)!;
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
                        self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, prop_key_idx);

                        // ES2015 §14.3: getter/setter names are prefixed with
                        // "get " or "set " so `o = { get foo() {} }; o.foo.name === "get foo"`.
                        // Always overwrite the inherited inferred name (from var
                        // `o = ...`), the property key + get/set prefix is the
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

                    // Compile the getter/setter function body, pass the
                    // source offset of the `get`/`set` keyword so the retained
                    // source span starts there (per ES2019 §19.2.3.5).
                    // Accessors are never generators or async; clear the flags
                    // so an accessor defined inside a generator/async body does
                    // not inherit the enclosing function's kind.
                    self.is_generator = false;
                    self.is_user_generator = false;
                    self.is_async = false;
                    if (!super_bound) {
                        // Give this object literal's `__super__` binding its own
                        // lexical environment record (PUSH_LEX) instead of
                        // re-declaring `let __super__` directly in the enclosing
                        // scope, otherwise a sibling object literal later in the
                        // same block clobbers the first literal's binding and
                        // corrupts already-created closures that captured it.
                        self.emit_simple(Opcode.PUSH_LEX);
                        ushort sup_reg = self.declare_var("__super__", LET);
                        uint sup_name_idx = self.add_string_constant("__super__");
                        self.emit_abc(Opcode.LDREG, (uint)sup_reg, (uint)obj_reg, 0);
                        self.emit_a_bc(Opcode.PUTLEX, (uint)sup_reg, sup_name_idx);
                        super_bound = true;
                    }
                    ushort accessor_reg = self.function_expr_body(key_src_start,
                        is_obj_getter ? AccessorKind.GETTER : AccessorKind.SETTER)!;
                    if (is_obj_getter) {
                        self.emit_abc(Opcode.INITGET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    } else {
                        self.emit_abc(Opcode.INITSET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    }
                    self.free_reg(accessor_reg);
                    self.free_reg(key_reg);
                    self.is_generator = saved_is_generator;
                    self.is_user_generator = saved_is_user_generator;
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
                self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx);

                // ES2015 §14.3 / §14.1.20: method name inference. Always overwrite
                // the inherited inferred name from the enclosing assignment, the
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
                self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx);
            } else if (key_tt == TokenType.BIGINT) {
                // ES2020 PropertyName: NumericLiteral (DecimalBigIntegerLiteral),
                // the property name is ToString(NumericValue(NumericLiteral)).
                // Load the BigInt then coerce via TOPROPKEY (same runtime path
                // as computed keys) rather than duplicating BigInt->string here.
                Token key_tok = self.advance()!;
                uint key_idx = self.add_bigint_constant(key_tok.str_value)!;
                key_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx);
                self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
            } else if (key_tt == TokenType.LBRACKET) {
                // Computed property key, clear inferred name since the actual
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
                // `*...expr` is not legal, restore flags and reject.
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
                self.record_error("expected a property name, '...', or '}' in object literal");
                return COMPILE_ERROR~;
            }

            // TypeScript generic method shorthand: `{ foo<T>(x: T) { ... } }`.
            // The `<...>` after the key is the method's own type-parameter
            // list (a comparison `foo < x` would be followed by an operator,
            // not `(`), so skip it and fall through to the method path below.
            if (self.lexer.ts_mode && self.check(TokenType.LT) && self.ts_peek_generics_lparen()) {
                self.skip_generic_params()!;
            }
            // Check for method shorthand or data property
            if (self.check(TokenType.LPAREN)) {
                // Method shorthand: key() { ... }, name inferred from key (set above)
                // Set the generator/async flags to exactly this method's own
                // kind (assign, not set-on-true: a plain method defined inside
                // a generator/async body must NOT inherit the enclosing
                // function's flags) and restore the saved flags immediately
                // after so the next iteration starts clean.
                self.is_generator = is_generator_method;
                self.is_user_generator = is_generator_method;
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
                self.is_user_generator = saved_is_user_generator;
                self.is_async = saved_is_async;
            } else if (is_shorthand_key && (self.check(TokenType.COMMA) || self.check(TokenType.RBRACE))) {
                // ES2015 §12.2.6.8: IdentifierReference shorthand property
                // `{ cause }` is equivalent to `{ cause: cause }`, the value
                // comes from the binding named by the key. Only legal when
                // the property key came from an IdentifierReference or
                // StringLiteral, never a numeric/computed key. `*a` shorthand
                // is not legal (must be a method), nor is `async a` (the
                // async modifier requires a method).
                if (is_generator_method || is_async_method) return COMPILE_ERROR~;
                // Read the binding into a register, then PUTPROP as usual.
                // Resolve as a local (parameter/let/const/var register) first,
                // matching plain IdentifierReference resolution in primary_expr
                //, and only fall back to a dynamic GETVAR-by-name lookup when
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
                    self.emit_ident_read((uint)val_reg, shorthand_name_idx);
                    self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                    self.free_reg(val_reg);
                }
                self.free_reg(key_reg);
                self.is_generator = saved_is_generator;
                self.is_async = saved_is_async;
            } else {
                // key: value, name inferred from key (set above)
                // `*a: 1` is not legal per ES2015 §14.3, generator shorthand
                // must be a method (`*a() {}`). Same for `async a: 1`.
                if (is_generator_method || is_async_method) return COMPILE_ERROR~;
                self.expect(TokenType.COLON)!;
                if (is_proto_key) {
                    // ES2015 §12.2.6.1: a second `__proto__: value` is an early
                    // SyntaxError.
                    if (seen_proto_key) return COMPILE_ERROR~;
                    seen_proto_key = true;
                    // `__proto__: fn` is a prototype-set, not a property
                    // definition, no NamedEvaluation (§12.2.6.8 step 5).
                    self.has_inferred_name = false;
                    self.inferred_name_len = 0;
                } else if (is_computed_key) {
                    // ES2015 §12.2.6.9 step 6: `IsAnonymousFunctionDefinition`
                    // is a static check on the value expression, independent of
                    // the (runtime-computed) key. Set has_inferred_name with an
                    // *empty* name so a following function/arrow/class/generator
                    // expression still consumes and clears the flag (leaving its
                    // compiled name empty, to be patched at runtime once the key
                    // is known, see INITPROPN/class_initaccessor_set_name).
                    // Anything that is NOT such an expression (identifier ref,
                    // comma expr, literal, ...) never touches the flag, so it
                    // stays set afterward, that's the signal used below to
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
    // Not an AnonymousFunctionDefinition, clear any pending inferred name
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
    ushort idx_reg = REG_NONE;
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
                    self.emit_a_sbx(Opcode.LDINT, (uint)one, 1);
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
                    self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index);
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
                    self.emit_a_sbx(Opcode.LDINT, (uint)one, 1);
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    // Compile-time index, use INITPROP (DefinePropertyOrThrow).
                    ushort idx_const = self.alloc_reg();
                    self.emit_a_sbx(Opcode.LDINT, (uint)idx_const, (int)index);
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
        self.emit_a_bc(Opcode.LDCONST, (uint)len_reg, len_const_idx);
        self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)len_reg, (uint)idx_reg);
        self.free_reg(len_reg);
    } else {
        self.emit_a_bc(Opcode.SETALEN, (uint)arr_reg, index);
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
fn void? CompilerContext.emit_forof_loop(&self, char[] var_name, ushort iter_reg, uint saved_scope, ushort saved_reg, bool is_lexical, bool is_const, bool is_bare, bool is_await = false) {
    // Declare loop variable register. (Per-iteration lexical env, §14.7.5.6, is
    // handled uniformly inside emit_forof.)
    ushort loop_var;
    bool reg_resident = false;
    if (is_bare) {
        // Bare `for (b of ...)` assigns to an existing binding. If that binding
        // is a register-cached local, bind straight into its home register so
        // the body's register read sees the value (PUTVAR alone desyncs it).
        if (!self.is_global) {
            if (try home = self.resolve_var(var_name)) {
                loop_var = home;
                reg_resident = true;
            } else {
                loop_var = self.alloc_reg();
            }
        } else {
            loop_var = self.alloc_reg();
        }
    } else {
        ScopeKind kind = is_const ? CONST : (is_lexical ? LET : VAR);
        self.check_var_lex_conflict(var_name, kind)!;
        loop_var = self.declare_binding_var(var_name, kind);
    }

    uint name_idx = self.add_string_constant(var_name);

    ForOfHead head;
    head.kind = IDENT;
    head.id_reg = loop_var;
    head.id_name_idx = name_idx;
    head.id_is_bare = is_bare;
    head.id_reg_resident = reg_resident;
    head.is_lexical = is_lexical;
    head.is_const = is_const;
    self.emit_forof(head, iter_reg, saved_scope, saved_reg, is_await)!;
}

