// Expression parsing.
module boomkat::ast;

import boomkat::lexer;

// Binary operator precedence; 0 means the token is not a binary operator here.
fn uint binop_prec(TokenType t, bool no_in) @inline {
    switch (t) {
        case TokenType.NULLISH: return 1;
        case TokenType.LOG_OR: return 2;
        case TokenType.LOG_AND: return 3;
        case TokenType.BIT_OR: return 4;
        case TokenType.BIT_XOR: return 5;
        case TokenType.BIT_AND: return 6;
        case TokenType.EQ:
        case TokenType.NE:
        case TokenType.SEQ:
        case TokenType.SNE: return 7;
        case TokenType.LT:
        case TokenType.GT:
        case TokenType.LE:
        case TokenType.GE:
        case TokenType.INSTANCEOF: return 8;
        case TokenType.IN: return no_in ? 0 : 8;
        case TokenType.SHL:
        case TokenType.SHR:
        case TokenType.USHR: return 9;
        case TokenType.PLUS:
        case TokenType.MINUS: return 10;
        case TokenType.STAR:
        case TokenType.SLASH:
        case TokenType.PERCENT: return 11;
        case TokenType.STARSTAR: return 12;
        default: return 0;
    }
}

fn bool is_assign_op(TokenType t) @inline {
    return t >= TokenType.ASSIGN && t <= TokenType.NULLISH_ASSIGN;
}

fn char op_flag(TokenType t) @inline {
    return (char)t.ordinal;
}

// An unparenthesised arrow function is an AssignmentExpression, so no operator, call or member
// access may follow it.
fn bool Parser.is_bare_arrow(&self, uint n) @inline {
    return self.ast.tags.data[n] == NodeTag.ARROW && (self.ast.flags.data[n] & FLAG_PAREN) == 0;
}

fn bool Parser.is_paren(&self, uint n) @inline {
    return (self.ast.flags.data[n] & FLAG_PAREN) != 0;
}

// ---- comma and assignment expressions ----

fn uint? Parser.expression(&self) {
    uint first = self.assign_expr()!;
    if (self.tok.type != TokenType.COMMA) return first;
    uint comma_pos = self.tok.pos;
    uint mark = self.scratch_mark();
    self.scratch_push(first);
    while (self.tok.type == TokenType.COMMA) {
        self.next()!;
        self.scratch_push(self.assign_expr()!);
    }
    return self.node(NodeTag.SEQUENCE, comma_pos, self.scratch_list(mark));
}

// An expression statement-level or head-level expression where a `{a = 1}` cover initialiser
// cannot become a pattern: reports it.
fn void? Parser.check_cover_init(&self) {
    if (self.cover_init != 0) {
        uint at = self.cover_init;
        self.cover_init = 0;
        return self.fail_at(at, "invalid shorthand property initializer")~;
    }
}

// A `{a = 1}` cover initialiser at or after `start` has become part of a pattern.
fn void Parser.claim_cover(&self, uint start) @inline {
    if (self.cover_init != 0 && self.cover_init >= start) self.cover_init = 0;
}

fn uint? Parser.assign_expr(&self) {
    self.check_stack()!;
    if (self.tok.type == TokenType.YIELD && self.ctx.is_generator) return self.yield_expr();

    uint lhs = self.conditional()!;
    TokenType op = self.tok.type;
    if (is_assign_op(op) && !self.is_bare_arrow(lhs)) {
        uint op_pos = self.tok.pos;
        NodeTag tag = self.ast.tags.data[lhs];
        if (op == TokenType.ASSIGN && !self.is_paren(lhs) && (tag == NodeTag.ARRAY || tag == NodeTag.OBJECT)) {
            self.to_pattern(lhs, false)!;
            self.claim_cover(self.ast.main_tok.data[lhs]);
        } else if (!self.is_simple_target(lhs, op != TokenType.ASSIGN)) {
            return self.fail_at(self.ast.main_tok.data[lhs], "invalid left-hand side in assignment")~;
        }
        self.next()!;
        uint rhs = self.assign_expr()!;
        return self.node(NodeTag.ASSIGN, op_pos, lhs, rhs, op_flag(op));
    }
    if (self.cover_depth == 0) self.check_cover_init()!;
    return lhs;
}

// A node that may be the target of `=`, `++`, a compound assignment or a for-in/of head.
// `compound` is true for operators other than `=` and for `++`/`--`, which take no pattern.
// A call is accepted in sloppy code: Annex B.3.9 defers it to a runtime ReferenceError.
fn bool Parser.is_simple_target(&self, uint n, bool compound) {
    switch (self.ast.tags.data[n]) {
        case NodeTag.IDENT:
        case NodeTag.MEMBER:
        case NodeTag.INDEX:
        case NodeTag.PRIVATE_MEMBER:
        case NodeTag.SUPER_MEMBER:
        case NodeTag.SUPER_INDEX:
            return true;
        case NodeTag.CALL:
            return !self.ctx.strict && (self.ast.flags.data[n] & FLAG_OPTIONAL) == 0;
        default:
            return false;
    }
}

fn uint? Parser.yield_expr(&self) {
    uint pos = self.tok.pos;
    if (self.tok.has_escape) return self.fail("keyword must not contain escaped characters")~;
    self.next()!;
    if (self.tok.nl_before) return self.node(NodeTag.YIELD, pos);
    if (self.tok.type == TokenType.STAR) {
        self.next()!;
        uint arg = self.assign_expr()!;
        return self.node(NodeTag.YIELD_STAR, pos, arg);
    }
    switch (self.tok.type) {
        case TokenType.RPAREN:
        case TokenType.RBRACKET:
        case TokenType.RBRACE:
        case TokenType.COMMA:
        case TokenType.SEMICOLON:
        case TokenType.COLON:
        case TokenType.EOF_TOKEN:
        case TokenType.IN:
            return self.node(NodeTag.YIELD, pos);
        default:
    }
    // `yield` before `of` in a for-of head or a template close is a bare yield; the cases above
    // are the tokens that cannot start an expression.
    uint arg = self.assign_expr()!;
    return self.node(NodeTag.YIELD, pos, arg);
}

fn uint? Parser.conditional(&self) {
    uint test = self.binary(1)!;
    if (self.tok.type != TokenType.QUESTION || self.is_bare_arrow(test)) return test;
    if (self.lex.ts_mode) {
        TokenType next = self.peek_type();
        if (next == TokenType.COLON || next == TokenType.COMMA || next == TokenType.RPAREN || next == TokenType.ASSIGN) return test;
    }
    uint pos = self.tok.pos;
    self.next()!;
    bool saved_no_in = self.no_in;
    self.no_in = false;
    uint cons = self.assign_expr()!;
    self.no_in = saved_no_in;
    uint colon = self.tok.pos;
    self.expect(TokenType.COLON)!;
    uint alt = self.assign_expr()!;
    return self.node(NodeTag.COND, pos, test, self.triple(cons, alt, colon));
}

fn uint? Parser.binary(&self, uint min_prec) {
    self.check_stack()!;
    uint left = self.unary()!;
    while (true) {
        if (self.lex.ts_mode && (self.at_word("as") || self.at_word("satisfies"))) {
            self.next()!;
            if (self.tok.type == TokenType.CONST) { self.next()!; }
            else { self.ts_skip_type(expression: true)!; }
            continue;
        }
        TokenType op = self.tok.type;
        uint prec = binop_prec(op, self.no_in);
        if (prec == 0 || prec < min_prec || self.is_bare_arrow(left)) break;
        if (op == TokenType.STARSTAR && !self.is_paren(left)) {
            NodeTag lt = self.ast.tags.data[left];
            if (lt == NodeTag.UNARY || lt == NodeTag.AWAIT) {
                return self.fail("unary operator used immediately before exponentiation expression")~;
            }
        }
        uint op_pos = self.tok.pos;
        self.next()!;
        uint right = self.binary(op == TokenType.STARSTAR ? prec : prec + 1)!;
        if (self.is_bare_arrow(right)) return self.fail_at(self.ast.main_tok.data[right], "arrow function must be parenthesised here")~;
        NodeTag t = (op == TokenType.LOG_AND || op == TokenType.LOG_OR || op == TokenType.NULLISH)
            ? NodeTag.LOGICAL : NodeTag.BINARY;
        left = self.node(t, op_pos, left, right, op_flag(op));
    }
    return left;
}

fn uint? Parser.unary(&self) {
    self.check_stack()!;
    TokenType t = self.tok.type;
    uint pos = self.tok.pos;
    switch (t) {
        case TokenType.DELETE:
        case TokenType.VOID:
        case TokenType.TYPEOF:
        case TokenType.PLUS:
        case TokenType.MINUS:
        case TokenType.BIT_NOT:
        case TokenType.LOG_NOT:
            self.next()!;
            uint operand = self.unary()!;
            if (self.is_bare_arrow(operand)) return self.fail_at(pos, "arrow function must be parenthesised here")~;
            return self.node(NodeTag.UNARY, pos, operand, 0, op_flag(t));
        case TokenType.INC:
        case TokenType.DEC:
            self.next()!;
            uint operand = self.unary()!;
            if (!self.is_simple_target(operand, true)) {
                return self.fail_at(self.ast.main_tok.data[operand], "invalid left-hand side expression in prefix operation")~;
            }
            return self.node(NodeTag.UPDATE_PRE, pos, operand, 0, op_flag(t));
        case TokenType.AWAIT:
            if (self.await_is_operator()) {
                if (self.tok.has_escape) return self.fail("keyword must not contain escaped characters")~;
                self.next()!;
                uint operand = self.unary()!;
                if (self.is_bare_arrow(operand)) return self.fail_at(pos, "arrow function must be parenthesised here")~;
                return self.node(NodeTag.AWAIT, pos, operand);
            }
        case TokenType.HASH_IDENT:
            // `#x in obj`: the only expression position a private name may take.
            uint name = self.atom(self.tok.str_value);
            self.next()!;
            if (self.tok.type != TokenType.IN || self.no_in) return self.fail_at(pos, "unexpected private name")~;
            self.next()!;
            uint right = self.binary(9)!;
            // The right operand is a ShiftExpression: neither another `#x in` nor an arrow.
            NodeTag rt = self.ast.tags.data[right];
            if (self.is_bare_arrow(right) || (rt == NodeTag.PRIVATE_IN && !self.is_paren(right))) {
                return self.fail_at(self.ast.main_tok.data[right], "invalid right operand of a private name `in`")~;
            }
            return self.node(NodeTag.PRIVATE_IN, pos, name, right);
        default:
    }
    return self.postfix();
}

fn uint? Parser.postfix(&self) {
    uint e = self.call_expr()!;
    if ((self.tok.type == TokenType.INC || self.tok.type == TokenType.DEC) && !self.tok.nl_before
        && !self.is_bare_arrow(e)) {
        if (!self.is_simple_target(e, true)) {
            return self.fail_at(self.ast.main_tok.data[e], "invalid left-hand side expression in postfix operation")~;
        }
        TokenType t = self.tok.type;
        uint pos = self.tok.pos;
        self.next()!;
        return self.node(NodeTag.UPDATE_POST, pos, e, 0, op_flag(t));
    }
    return e;
}

// ---- calls, members, new ----

fn uint? Parser.call_expr(&self) {
    self.check_stack()!;
    uint e;
    switch (self.tok.type) {
        case TokenType.NEW:
            e = self.new_expr()!;
        case TokenType.SUPER:
            e = self.super_expr()!;
        case TokenType.IMPORT:
            e = self.import_expr()!;
        default:
            e = self.primary()!;
    }
    return self.call_tail(e, true);
}

fn uint? Parser.name_node_atom(&self) {
    // Property name after `.` or `?.`: any IdentifierName.
    if (!is_name_token(self.tok.type)) return self.unexpected()~;
    uint a = self.atom(self.tok.str_value);
    self.next(true)!;
    return a;
}

// Member accesses, calls and tagged templates after `e`. With `allow_call` false (the callee of
// `new`) only member accesses and templates continue the expression.
fn uint? Parser.call_tail(&self, uint e_in, bool allow_call) {
    uint e = e_in;
    if (self.is_bare_arrow(e)) return e;
    bool chain = false;
    while (true) {
        uint pos = self.tok.pos;
        if (self.lex.ts_mode && self.tok.type == TokenType.LT && self.ts_type_arguments()) continue;
        switch (self.tok.type) {
            case TokenType.LOG_NOT:
                if (!self.lex.ts_mode || self.tok.nl_before) return self.finish_chain(e, chain);
                self.next()!;
            case TokenType.DOT:
                self.next()!;
                if (self.tok.type == TokenType.HASH_IDENT) {
                    uint a = self.atom(self.tok.str_value);
                    self.next()!;
                    e = self.node(NodeTag.PRIVATE_MEMBER, pos, e, a);
                } else {
                    uint a = self.name_node_atom()!;
                    e = self.node(NodeTag.MEMBER, pos, e, a);
                }
            case TokenType.OPT_CHAIN:
                if (!allow_call) return self.fail("invalid optional chain from new expression")~;
                chain = true;
                self.next()!;
                switch (self.tok.type) {
                    case TokenType.LPAREN:
                        uint args = self.arguments(false)!;
                        e = self.node(NodeTag.CALL, pos, e, args, FLAG_OPTIONAL);
                    case TokenType.LBRACKET:
                        self.next()!;
                        bool saved = self.no_in;
                        self.no_in = false;
                        uint key = self.expression()!;
                        self.no_in = saved;
                        self.expect(TokenType.RBRACKET)!;
                        e = self.node(NodeTag.INDEX, pos, e, key, FLAG_OPTIONAL);
                    case TokenType.HASH_IDENT:
                        uint a = self.atom(self.tok.str_value);
                        self.next()!;
                        e = self.node(NodeTag.PRIVATE_MEMBER, pos, e, a, FLAG_OPTIONAL);
                    default:
                        if (self.tok.is_template || self.tok.type == TokenType.TEMPLATE_HEAD) {
                            return self.fail("invalid tagged template on optional chain")~;
                        }
                        uint a = self.name_node_atom()!;
                        e = self.node(NodeTag.MEMBER, pos, e, a, FLAG_OPTIONAL);
                }
            case TokenType.LBRACKET:
                self.next()!;
                bool saved = self.no_in;
                self.no_in = false;
                uint key = self.expression()!;
                self.no_in = saved;
                self.expect(TokenType.RBRACKET)!;
                e = self.node(NodeTag.INDEX, pos, e, key);
            case TokenType.LPAREN:
                if (!allow_call) return self.finish_chain(e, chain);
                bool maybe_async_arrow = self.is_async_ident(e) && !self.tok.nl_before;
                uint callee_start = self.ast.main_tok.data[e];
                uint args = self.arguments(maybe_async_arrow)!;
                if (maybe_async_arrow) self.ts_arrow_return_annotation();
                if (maybe_async_arrow && self.tok.type == TokenType.ARROW && !self.tok.nl_before) {
                    return self.arrow_from_list(args, true, callee_start);
                }
                if (maybe_async_arrow && self.cover_depth == 0) self.check_cover_init()!;
                e = self.node(NodeTag.CALL, pos, e, args);
            case TokenType.STRING:
            case TokenType.TEMPLATE_HEAD:
                if (self.tok.type == TokenType.STRING && !self.tok.is_template) return self.finish_chain(e, chain);
                if (chain) return self.fail("invalid tagged template on optional chain")~;
                uint tpl = self.template(true)!;
                e = self.node(NodeTag.TAGGED_TEMPLATE, pos, e, tpl);
            default:
                return self.finish_chain(e, chain);
        }
    }
}

fn uint Parser.finish_chain(&self, uint e, bool chain) {
    if (!chain) return e;
    return self.node(NodeTag.OPT_CHAIN, self.ast.main_tok.data[e], e);
}

// `async` as a plain identifier, the callee of a possible async arrow function head.
fn bool Parser.is_async_ident(&self, uint n) {
    if (self.ast.tags.data[n] != NodeTag.IDENT || self.is_paren(n)) return false;
    if ((self.ast.flags.data[n] & IDENT_ESCAPED) != 0) return false;
    char[] s = self.ast.atoms.get(self.ast.lhs.data[n]);
    return s.len == 5 && s[0] == 'a' && s[1] == 's' && s[2] == 'y' && s[3] == 'n' && s[4] == 'c';
}

// Arguments `( ... )`. With `as_params`, `{a = 1}` cover initialisers may belong to arrow
// parameters and are left for the caller to claim.
fn uint? Parser.arguments(&self, bool as_params) {
    self.expect(TokenType.LPAREN)!;
    bool saved = self.no_in;
    self.no_in = false;
    if (as_params) self.cover_depth++;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RPAREN) {
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint pos = self.tok.pos;
            self.next()!;
            uint arg = self.assign_expr()!;
            if (as_params) self.ts_annotation()!;
            uint spread = self.node(NodeTag.SPREAD, pos, arg);
            self.scratch_push(spread);
            if (self.tok.type == TokenType.COMMA) self.ast.flags.data[spread] |= SPREAD_COMMA;
        } else {
            uint param = self.assign_expr()!;
            if (as_params) {
                self.ts_annotation(optional: true)!;
                if (self.lex.ts_mode && self.tok.type == TokenType.ASSIGN) {
                    uint pos = self.tok.pos;
                    self.next()!;
                    param = self.node(NodeTag.ASSIGN, pos, param, self.assign_expr()!, op_flag(TokenType.ASSIGN));
                }
            }
            self.scratch_push(param);
        }
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    if (as_params) self.cover_depth--;
    self.no_in = saved;
    self.expect(TokenType.RPAREN)!;
    return self.scratch_list(mark);
}

fn uint? Parser.new_expr(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    if (self.tok.type == TokenType.DOT) {
        self.next()!;
        if (!self.at_word("target")) return self.unexpected()~;
        if (!self.ctx.allow_new_target) return self.fail("new.target is not allowed here")~;
        self.next()!;
        return self.node(NodeTag.NEW_TARGET, pos);
    }
    uint callee;
    switch (self.tok.type) {
        case TokenType.NEW:
            callee = self.new_expr()!;
        case TokenType.SUPER:
            callee = self.super_expr()!;
        case TokenType.IMPORT:
            // `new import.meta()` is a MemberExpression; `new import(x)` and `new import.defer(x)` are not.
            if (self.peek_type() != TokenType.DOT) return self.fail("cannot use new with import")~;
            callee = self.import_expr()!;
            if (self.ast.tags.data[callee] != NodeTag.IMPORT_META) return self.fail_at(pos, "cannot use new with import")~;
        default:
            callee = self.primary()!;
    }
    callee = self.call_tail(callee, false)!;
    uint args;
    if (self.tok.type == TokenType.LPAREN) {
        args = self.arguments(false)!;
    } else {
        args = self.ast.add_list({});
    }
    return self.node(NodeTag.NEW, pos, callee, args);
}

fn uint? Parser.super_expr(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    switch (self.tok.type) {
        case TokenType.LPAREN:
            if (!self.ctx.allow_super_call) return self.fail_at(pos, "'super' keyword unexpected here")~;
            uint args = self.arguments(false)!;
            return self.node(NodeTag.SUPER_CALL, pos, 0, args);
        case TokenType.DOT:
            if (!self.ctx.allow_super_property) return self.fail_at(pos, "'super' keyword unexpected here")~;
            self.next()!;
            uint a = self.name_node_atom()!;
            return self.node(NodeTag.SUPER_MEMBER, pos, 0, a);
        case TokenType.LBRACKET:
            if (!self.ctx.allow_super_property) return self.fail_at(pos, "'super' keyword unexpected here")~;
            self.next()!;
            bool saved = self.no_in;
            self.no_in = false;
            uint key = self.expression()!;
            self.no_in = saved;
            self.expect(TokenType.RBRACKET)!;
            return self.node(NodeTag.SUPER_INDEX, pos, 0, key);
        default:
            return self.fail_at(pos, "'super' keyword unexpected here")~;
    }
}

fn uint? Parser.import_expr(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    char phase = 0;
    if (self.tok.type == TokenType.DOT) {
        self.next()!;
        if (self.at_word("defer") || self.at_word("source")) {
            phase = self.at_word("defer") ? IMPORT_CALL_DEFER : IMPORT_CALL_SOURCE;
            self.next()!;
        } else {
            if (!self.at_word("meta")) return self.unexpected()~;
            if (!self.is_module) return self.fail_at(pos, "cannot use 'import.meta' outside a module")~;
            self.next()!;
            return self.node(NodeTag.IMPORT_META, pos);
        }
    }
    if (self.tok.type != TokenType.LPAREN) return self.unexpected()~;
    self.next()!;
    bool saved = self.no_in;
    self.no_in = false;
    uint spec = self.assign_expr()!;
    uint opts = 0;
    if (self.tok.type == TokenType.COMMA) {
        self.next()!;
        if (self.tok.type != TokenType.RPAREN) {
            opts = self.assign_expr()!;
            if (self.tok.type == TokenType.COMMA) self.next()!;
        }
    }
    self.no_in = saved;
    self.expect(TokenType.RPAREN)!;
    return self.node(NodeTag.IMPORT_CALL, pos, spec, opts, phase);
}

// ---- primary expressions ----

fn uint Parser.number_node(&self) {
    double d = self.tok.num_value;
    ulong bits = bitcast(d, ulong);
    return self.node(NodeTag.NUMBER, self.tok.pos, (uint)(bits & 0xFFFFFFFF), (uint)(bits >> 32));
}

fn uint? Parser.primary(&self) {
    self.check_stack()!;
    Token t = self.tok;
    switch (t.type) {
        case TokenType.LT:
            if (!self.lex.ts_mode) return self.unexpected()~;
            self.ts_skip_generic_params()!;
            if (self.tok.type != TokenType.LPAREN) return self.fail_at(t.pos, "angle-bracket assertions are not supported (not erasable syntax)")~;
            uint arrow = self.paren_or_arrow()!;
            if (self.ast.tags.data[arrow] != NodeTag.ARROW) return self.fail_at(t.pos, "angle-bracket assertions are not supported (not erasable syntax)")~;
            return arrow;
        case TokenType.NUMBER:
            uint n = self.number_node();
            self.next()!;
            return n;
        case TokenType.BIGINT:
            uint n = self.node(NodeTag.BIGINT, t.pos, self.atom(t.str_value));
            self.next()!;
            return n;
        case TokenType.STRING:
            if (t.is_template) return self.template(false);
            uint n = self.string_node(t);
            self.next()!;
            return n;
        case TokenType.TEMPLATE_HEAD:
            return self.template(false);
        case TokenType.SLASH:
        case TokenType.SLASH_ASSIGN:
            self.rescan_regex()!;
            uint n = self.node(NodeTag.REGEX, self.tok.pos, self.atom(self.lex.source[self.tok.pos:self.tok.end - self.tok.pos]));
            self.next()!;
            return n;
        case TokenType.THIS:
            self.next()!;
            return self.node(NodeTag.THIS, t.pos);
        case TokenType.LPAREN:
            return self.paren_or_arrow();
        case TokenType.LBRACKET:
            return self.array_literal();
        case TokenType.LBRACE:
            return self.object_literal();
        case TokenType.FUNCTION:
            return self.function_expr(t.pos, false);
        case TokenType.CLASS:
            return self.class_expr();
        case TokenType.IDENTIFIER:
            if (!t.has_escape) {
                if (self.is_word(t, "null")) { self.next()!; return self.node(NodeTag.NULL_LIT, t.pos); }
                if (self.is_word(t, "true")) { self.next()!; return self.node(NodeTag.TRUE_LIT, t.pos); }
                if (self.is_word(t, "false")) { self.next()!; return self.node(NodeTag.FALSE_LIT, t.pos); }
                if (self.is_word(t, "async")) return self.async_primary();
            }
            return self.ident_or_arrow();
        case TokenType.LET:
        case TokenType.STATIC:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            if (self.is_ident_token(t)) return self.ident_or_arrow();
            return self.unexpected()~;
        default:
            return self.unexpected()~;
    }
}

fn uint Parser.string_node(&self, Token t) {
    char f = (t.has_octal_escape || t.has_decoded_octal) ? STR_OCTAL : 0;
    return self.node(NodeTag.STRING, t.pos, self.atom(t.str_value), 0, f);
}

fn uint Parser.ident_node(&self, Token t) {
    return self.node(NodeTag.IDENT, t.pos, self.atom(t.str_value), 0, t.has_escape ? IDENT_ESCAPED : 0);
}

// An identifier reference, or the single parameter of `x => ...`.
fn uint? Parser.ident_or_arrow(&self) {
    Token t = self.tok;
    if (self.peek_type() == TokenType.ARROW && !self.peek_tok.nl_before) {
        uint id = self.ident_node(t);
        self.next()!;
        uint params = self.ast.add_list({ id });
        return self.arrow_rest(params, false, t.pos);
    }
    self.next()!;
    return self.ident_node(t);
}

// `async` begins an async function expression, an async arrow, or is a plain identifier.
fn uint? Parser.async_primary(&self) {
    Token t = self.tok;
    Token? pk = self.peek();
    if (catch err = pk) return err~;
    if (pk.type == TokenType.FUNCTION && !pk.nl_before) {
        self.next()!;
        return self.function_expr(t.pos, true);
    }
    if (!pk.nl_before && self.is_ident_token(pk) ) {
        // `async x => ...`
        self.next()!;
        Token param = self.tok;
        self.next()!;
        if (self.tok.type != TokenType.ARROW || self.tok.nl_before) {
            // Not an arrow head (`for await (async of x)`): `async` is an identifier and the
            // token after it is rescanned.
            self.lex.seek_to_token(param);
            self.has_peek = false;
            self.tok = t;
            self.next()!;
            self.prev = t;
            return self.ident_node(t);
        }
        uint id = self.ident_node(param);
        uint params = self.ast.add_list({ id });
        return self.arrow_rest(params, true, t.pos);
    }
    return self.ident_or_arrow();
}

// ---- parenthesised expressions and arrow functions ----

fn uint? Parser.paren_or_arrow(&self) {
    uint open = self.tok.pos;
    self.next()!;
    bool saved_no_in = self.no_in;
    self.no_in = false;
    self.cover_depth++;
    uint mark = self.scratch_mark();
    bool trailing_comma = false;
    bool has_rest = false;
    while (self.tok.type != TokenType.RPAREN) {
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint pos = self.tok.pos;
            self.next()!;
            uint target = self.binding_target()!;
            self.ts_annotation()!;
            self.scratch_push(self.node(NodeTag.REST, pos, target));
            has_rest = true;
            break;
        }
        uint param = self.assign_expr()!;
        self.ts_annotation(optional: true)!;
        if (self.lex.ts_mode && self.tok.type == TokenType.ASSIGN) {
            uint pos = self.tok.pos;
            self.next()!;
            param = self.node(NodeTag.ASSIGN, pos, param, self.assign_expr()!, (char)TokenType.ASSIGN);
        }
        self.scratch_push(param);
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
        if (self.tok.type == TokenType.RPAREN) trailing_comma = true;
    }
    uint count = (uint)self.scratch.len - mark;
    self.cover_depth--;
    self.no_in = saved_no_in;
    self.expect(TokenType.RPAREN)!;
    self.ts_arrow_return_annotation();
    if (self.tok.type == TokenType.ARROW && !self.tok.nl_before) {
        uint list = self.scratch_list(mark);
        return self.arrow_from_list(list, false, open);
    }
    if (count == 0 || has_rest || trailing_comma) {
        self.scratch.truncate(mark);
        return self.fail("unexpected token in parenthesised expression")~;
    }
    if (self.cover_depth == 0) self.check_cover_init()!;
    uint inner;
    if (count == 1) {
        inner = self.scratch.data[mark];
        self.scratch.truncate(mark);
    } else {
        inner = self.node(NodeTag.SEQUENCE, open, self.scratch_list(mark));
    }
    self.ast.flags.data[inner] |= FLAG_PAREN;
    return inner;
}

// Turn the expressions of a parenthesised list or call into arrow parameters, then parse the arrow.
fn uint? Parser.arrow_from_list(&self, uint list, bool is_async, uint src_start) {
    uint n = self.ast.list_len(list);
    for (uint i = 0; i < n; i++) {
        uint item = self.ast.list_item(list, i);
        NodeTag tag = self.ast.tags.data[item];
        if (tag == NodeTag.SPREAD) {
            if (i + 1 != n || (self.ast.flags.data[item] & SPREAD_COMMA) != 0) {
                return self.fail("rest parameter must be last formal parameter")~;
            }
            self.ast.tags.data[item] = NodeTag.REST;
            self.to_pattern(self.ast.lhs.data[item], true)!;
        } else if (tag == NodeTag.REST) {
            // Built directly by paren_or_arrow with a binding target already.
        } else {
            self.to_pattern_element(item, true)!;
        }
    }
    self.claim_cover(src_start);
    return self.arrow_rest(list, is_async, src_start);
}

// The `=>` and body of an arrow function whose parameters are done.
fn uint? Parser.arrow_rest(&self, uint params, bool is_async, uint src_start) {
    if (self.tok.type != TokenType.ARROW || self.tok.nl_before) return self.unexpected()~;
    uint header_end = self.tok.pos;
    self.next()!;
    FnCtx saved = self.ctx;
    self.ctx.is_async = is_async;
    self.ctx.is_generator = false;
    self.ctx.is_arrow = true;
    self.ctx.top_level_await = false;
    self.ctx.in_params = false;
    self.ctx.in_static_block = false;
    uint fnf = is_async ? FNF_ASYNC : 0;
    uint body;
    uint body_start = self.tok.pos;
    bool saved_cover_init = self.cover_init != 0;
    uint saved_depth = self.cover_depth;
    self.cover_depth = 0;
    if (self.tok.type == TokenType.LBRACE) {
        bool saved_no_in = self.no_in;
        self.no_in = false;
        self.ctx.in_function = true;
        body = self.function_block(&fnf)!;
        self.no_in = saved_no_in;
    } else {
        fnf |= FNF_EXPR_BODY;
        self.ctx.in_function = false;
        body = self.assign_expr()!;
        if (self.ctx.strict) fnf |= FNF_STRICT;
    }
    self.cover_depth = saved_depth;
    self.ctx = saved;
    if (self.params_are_simple(params)) fnf |= FNF_SIMPLE_PARAMS;
    if (self.ctx.strict) fnf |= FNF_STRICT;
    uint rec = self.fn_record(fnf, params, body, src_start, self.prev.end);
    self.ast.set_field(rec, FN_BODY_START, body_start);
    self.ast.set_field(rec, FN_HEADER_END, header_end);
    return self.node(NodeTag.ARROW, src_start, 0, rec);
}

fn uint Parser.fn_record(&self, uint fnf, uint params, uint body, uint src_start, uint src_end) {
    uint rec = self.ast.add_record(FN_SIZE);
    self.ast.set_field(rec, FN_FLAGS, fnf);
    self.ast.set_field(rec, FN_PARAMS, params);
    self.ast.set_field(rec, FN_BODY, body);
    self.ast.set_field(rec, FN_SRC_START, src_start);
    self.ast.set_field(rec, FN_SRC_END, src_end);
    return rec;
}

fn bool Parser.params_are_simple(&self, uint params) {
    uint n = self.ast.list_len(params);
    for (uint i = 0; i < n; i++) {
        if (self.ast.tags.data[self.ast.list_item(params, i)] != NodeTag.IDENT) return false;
    }
    return true;
}

// ---- literals ----

// A template literal. `tagged` templates accept invalid escape sequences, whose cooked value is
// INVALID_ATOM.
fn uint? Parser.template(&self, bool tagged) {
    uint pos = self.tok.pos;
    uint mark = self.scratch_mark();
    if (self.tok.type == TokenType.STRING) {
        self.template_part(tagged)!;
        self.next()!;
        return self.node(NodeTag.TEMPLATE, pos, self.scratch_list(mark));
    }
    bool saved_no_in = self.no_in;
    while (true) {
        // The token is TEMPLATE_HEAD or TEMPLATE_MIDDLE.
        self.template_part(tagged)!;
        self.next()!;
        self.no_in = false;
        self.scratch_push(self.expression()!);
        self.no_in = saved_no_in;
        if (self.tok.type != TokenType.RBRACE) return self.fail("expected '}' in template literal")~;
        self.rescan_template()!;
        if (self.tok.type == TokenType.TEMPLATE_TAIL) {
            self.template_part(tagged)!;
            self.next()!;
            break;
        }
    }
    return self.node(NodeTag.TEMPLATE, pos, self.scratch_list(mark));
}

// Push the cooked and raw atoms of the current template text token.
fn void? Parser.template_part(&self, bool tagged) {
    Token t = self.tok;
    uint cooked;
    if (t.has_invalid_escape) {
        if (!tagged) return self.fail("invalid escape sequence in template literal")~;
        cooked = INVALID_ATOM;
    } else {
        cooked = self.atom(t.str_value);
    }
    self.scratch_push(cooked);
    self.scratch_push(self.atom(t.raw_value));
    self.scratch_push(t.pos);
}

fn uint? Parser.array_literal(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    bool saved_no_in = self.no_in;
    self.no_in = false;
    self.cover_depth++;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACKET) {
        if (self.tok.type == TokenType.COMMA) {
            self.next()!;
            self.scratch_push(0);
            continue;
        }
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint spos = self.tok.pos;
            self.next()!;
            uint arg = self.assign_expr()!;
            uint spread = self.node(NodeTag.SPREAD, spos, arg);
            self.scratch_push(spread);
            if (self.tok.type == TokenType.COMMA) self.ast.flags.data[spread] |= SPREAD_COMMA;
        } else {
            self.scratch_push(self.assign_expr()!);
        }
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.cover_depth--;
    self.no_in = saved_no_in;
    self.expect(TokenType.RBRACKET)!;
    return self.node(NodeTag.ARRAY, pos, self.scratch_list(mark));
}

// A property key: an IdentifierName or string becomes a STRING node, a number a NUMBER, `[expr]` the
// expression with `computed` set, and `#x` a PRIVATE_NAME.
fn uint? Parser.prop_key(&self, bool* computed) {
    Token t = self.tok;
    *computed = false;
    switch (t.type) {
        case TokenType.STRING:
            if (t.is_template) return self.unexpected()~;
            uint n = self.string_node(t);
            self.next()!;
            return n;
        case TokenType.NUMBER:
            uint n = self.number_node();
            self.next()!;
            return n;
        case TokenType.BIGINT:
            uint n = self.node(NodeTag.BIGINT, t.pos, self.atom(t.str_value));
            self.next()!;
            return n;
        case TokenType.LBRACKET:
            self.next()!;
            bool saved = self.no_in;
            self.no_in = false;
            uint e = self.assign_expr()!;
            self.no_in = saved;
            self.expect(TokenType.RBRACKET)!;
            *computed = true;
            return e;
        case TokenType.HASH_IDENT:
            uint n = self.node(NodeTag.PRIVATE_NAME, t.pos, self.atom(t.str_value));
            self.next()!;
            return n;
        default:
            if (!is_name_token(t.type)) return self.unexpected()~;
            uint n = self.node(NodeTag.STRING, t.pos, self.atom(t.str_value));
            self.next(true)!;
            return n;
    }
}

// After a `get`, `set` or `async` word: does a property key follow, making it a modifier?
fn bool Parser.modifier_applies(&self, bool star_follows_ok) {
    Token? pk = self.peek();
    if (catch err = pk) return false;
    switch (pk.type) {
        case TokenType.COMMA:
        case TokenType.COLON:
        case TokenType.LPAREN:
        case TokenType.RBRACE:
        case TokenType.ASSIGN:
        case TokenType.SEMICOLON:
        case TokenType.EOF_TOKEN:
            return false;
        case TokenType.STAR:
            return star_follows_ok;
        default:
            return true;
    }
}

fn uint? Parser.object_literal(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    bool saved_no_in = self.no_in;
    self.no_in = false;
    self.cover_depth++;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        self.scratch_push(self.object_property()!);
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.cover_depth--;
    self.no_in = saved_no_in;
    self.expect(TokenType.RBRACE)!;
    return self.node(NodeTag.OBJECT, pos, self.scratch_list(mark));
}

fn uint? Parser.object_property(&self) {
    Token start = self.tok;
    if (start.type == TokenType.ELLIPSIS) {
        self.next()!;
        uint arg = self.assign_expr()!;
        char sflag = self.tok.type == TokenType.COMMA ? SPREAD_COMMA : 0;
        return self.node(NodeTag.PROP_SPREAD, start.pos, arg, 0, sflag);
    }
    bool is_async = false;
    bool is_gen = false;
    NodeTag kind = NodeTag.PROP_INIT;
    if (self.is_word(start, "async") && !self.peek_tok_nl_after_async() && self.modifier_applies(true)) {
        is_async = true;
        self.next()!;
    }
    if (self.tok.type == TokenType.STAR) {
        is_gen = true;
        self.next()!;
    }
    if (!is_async && !is_gen && self.tok.type == TokenType.IDENTIFIER && !self.tok.has_escape
        && (self.at_word("get") || self.at_word("set")) && self.modifier_applies(false)) {
        kind = self.at_word("get") ? NodeTag.PROP_GET : NodeTag.PROP_SET;
        self.next()!;
    }
    Token key_tok = self.tok;
    bool computed;
    uint key = self.prop_key(&computed)!;
    char cflag = computed ? PROP_COMPUTED : 0;
    if (self.lex.ts_mode && self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
    if (kind == NodeTag.PROP_GET || kind == NodeTag.PROP_SET) {
        uint fnf = FNF_METHOD | (kind == NodeTag.PROP_GET ? FNF_GETTER : FNF_SETTER);
        uint func = self.method_function(start.pos, fnf, false)!;
        return self.node(kind, start.pos, key, func, cflag);
    }
    if (is_async || is_gen || self.tok.type == TokenType.LPAREN) {
        uint fnf = FNF_METHOD | (is_async ? FNF_ASYNC : 0) | (is_gen ? FNF_GENERATOR : 0);
        uint func = self.method_function(start.pos, fnf, false)!;
        return self.node(NodeTag.PROP_METHOD, start.pos, key, func, cflag);
    }
    if (self.tok.type == TokenType.COLON) {
        self.next()!;
        uint value = self.assign_expr()!;
        return self.node(NodeTag.PROP_INIT, start.pos, key, value, cflag);
    }
    // Shorthand `a` or the cover initialiser `a = 1`.
    if (computed || !self.is_ident_token(key_tok)) {
        if (key_tok.type == TokenType.YIELD || key_tok.type == TokenType.AWAIT) {
            return self.fail_at(key_tok.pos, "unexpected reserved word")~;
        }
        return self.unexpected()~;
    }
    uint ident = self.ident_node(key_tok);
    uint dflt = 0;
    if (self.tok.type == TokenType.ASSIGN) {
        if (self.cover_init == 0) self.cover_init = self.tok.pos;
        self.next()!;
        dflt = self.assign_expr()!;
    }
    return self.node(NodeTag.PROP_SHORTHAND, start.pos, ident, dflt);
}

fn bool Parser.peek_tok_nl_after_async(&self) {
    Token? pk = self.peek();
    if (catch err = pk) return true;
    return pk.nl_before;
}
