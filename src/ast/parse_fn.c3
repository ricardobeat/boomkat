// Functions, classes, binding patterns and cover-grammar conversion.
module boomkat::ast;

import boomkat::lexer;

// ---- functions ----

// `function [*] name (...) {...}` as a declaration. The current token is `function`; for an async
// function the `async` word has been consumed and `start` is its position.
fn uint? Parser.function_decl(&self, uint start, bool is_async) {
    return self.function_named(start, is_async, true, false);
}

fn uint? Parser.function_expr(&self, uint start, bool is_async) {
    return self.function_named(start, is_async, false, false);
}

// A function with an optional name. `anonymous_ok` allows a declaration without a name
// (`export default function () {}`).
fn uint? Parser.function_named(&self, uint start, bool is_async, bool decl, bool anonymous_ok) {
    self.next()!;
    uint fnf = is_async ? FNF_ASYNC : 0;
    if (self.tok.type == TokenType.STAR) {
        fnf |= FNF_GENERATOR;
        self.next()!;
    }
    uint name = 0;
    if (self.tok.type != TokenType.LPAREN) {
        // A function expression's own name is bound in its own scope, so `yield` and `await`
        // follow the function's kind rather than the enclosing one.
        Token nt = self.tok;
        bool ok;
        if (decl) {
            ok = self.is_ident_token(nt);
        } else {
            ok = nt.type == TokenType.IDENTIFIER || nt.type == TokenType.LET || nt.type == TokenType.STATIC
                || (nt.type == TokenType.YIELD && (fnf & FNF_GENERATOR) == 0)
                || (nt.type == TokenType.AWAIT && (fnf & FNF_ASYNC) == 0 && !self.is_module);
        }
        if (!ok) return self.unexpected()~;
        name = self.ident_node(nt);
        self.next()!;
    } else if (decl && !anonymous_ok) {
        return self.unexpected()~;
    }
    uint rec = self.function_tail(start, fnf)!;
    return self.node(decl ? NodeTag.FUNC_DECL : NodeTag.FUNC_EXPR, start, name, rec);
}

// An object or class method: the parameter list and body, returned as a nameless FUNC_EXPR.
fn uint? Parser.method_function(&self, uint start, uint fnf, bool unused) {
    uint rec = self.function_tail(start, fnf)!;
    return self.node(NodeTag.FUNC_EXPR, start, 0, rec);
}

// Parameters and body of a function whose `(` is the current token. Returns the function record.
fn uint? Parser.function_tail(&self, uint start, uint fnf_in) {
    self.check_stack()!;
    uint fnf = fnf_in;
    FnCtx saved = self.ctx;
    bool saved_no_in = self.no_in;
    uint saved_depth = self.cover_depth;
    self.no_in = false;
    self.cover_depth = 0;
    self.ctx.is_async = (fnf & FNF_ASYNC) != 0;
    self.ctx.is_generator = (fnf & FNF_GENERATOR) != 0;
    self.ctx.is_arrow = false;
    self.ctx.in_function = true;
    self.ctx.top_level_await = false;
    self.ctx.in_static_block = false;
    self.ctx.in_field_init = false;
    self.ctx.allow_new_target = true;
    self.ctx.allow_super_property = (fnf & FNF_METHOD) != 0;
    self.ctx.allow_super_call = (fnf & FNF_DERIVED_CTOR) != 0;
    self.ctx.in_params = true;
    uint params = self.formal_params()!;
    self.ctx.in_params = false;
    uint body = self.function_block(&fnf)!;
    self.ctx = saved;
    self.no_in = saved_no_in;
    self.cover_depth = saved_depth;
    if (self.params_are_simple(params)) fnf |= FNF_SIMPLE_PARAMS;
    return self.fn_record(fnf, params, body, start, self.prev.end);
}

// `( params )`: patterns with optional defaults and a final rest element.
fn uint? Parser.formal_params(&self) {
    self.expect(TokenType.LPAREN)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RPAREN) {
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint pos = self.tok.pos;
            self.next()!;
            uint target = self.binding_target()!;
            self.scratch_push(self.node(NodeTag.REST, pos, target));
            if (self.tok.type != TokenType.RPAREN) return self.fail("rest parameter must be last formal parameter")~;
            break;
        }
        self.scratch_push(self.binding_element()!);
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RPAREN)!;
    return self.scratch_list(mark);
}

// `{ directives statements }` of a function body. Sets FNF_USE_STRICT and FNF_STRICT.
fn uint? Parser.function_block(&self, uint* fnf) {
    uint pos = self.tok.pos;
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    char flags = 0;
    self.directive_prologue(mark, &flags)!;
    if ((flags & PROGRAM_STRICT) != 0) *fnf |= FNF_USE_STRICT;
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.statement_list_item_in_block()!);
    }
    if (self.ctx.strict) *fnf |= FNF_STRICT;
    self.next()!;
    return self.node(NodeTag.BLOCK, pos, self.scratch_list(mark));
}

// ---- binding patterns ----

fn uint? Parser.binding_target(&self) {
    self.check_stack()!;
    switch (self.tok.type) {
        case TokenType.LBRACKET:
            return self.array_binding();
        case TokenType.LBRACE:
            return self.object_binding();
        default:
            if (!self.is_ident_token(self.tok)) return self.unexpected()~;
            Token t = self.tok;
            self.next()!;
            return self.ident_node(t);
    }
}

// A binding target with an optional `= default`.
fn uint? Parser.binding_element(&self) {
    uint target = self.binding_target()!;
    if (self.tok.type != TokenType.ASSIGN) return target;
    uint pos = self.tok.pos;
    self.next()!;
    bool saved = self.no_in;
    self.no_in = false;
    uint dflt = self.assign_expr()!;
    self.no_in = saved;
    return self.node(NodeTag.ASSIGN_PAT, pos, target, dflt);
}

fn uint? Parser.array_binding(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACKET) {
        if (self.tok.type == TokenType.COMMA) {
            self.next()!;
            self.scratch_push(0);
            continue;
        }
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint rpos = self.tok.pos;
            self.next()!;
            uint target = self.binding_target()!;
            self.scratch_push(self.node(NodeTag.REST, rpos, target));
            if (self.tok.type != TokenType.RBRACKET) return self.fail("rest element must be last element")~;
            break;
        }
        self.scratch_push(self.binding_element()!);
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RBRACKET)!;
    return self.node(NodeTag.ARRAY_PAT, pos, self.scratch_list(mark));
}

fn uint? Parser.object_binding(&self) {
    uint pos = self.tok.pos;
    self.next()!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        Token start = self.tok;
        if (start.type == TokenType.ELLIPSIS) {
            self.next()!;
            uint target = self.binding_target()!;
            if (self.ast.tags.data[target] != NodeTag.IDENT) return self.fail_at(start.pos, "rest element must be an identifier")~;
            self.scratch_push(self.node(NodeTag.REST, start.pos, target));
            if (self.tok.type != TokenType.RBRACE) return self.fail("rest element must be last element")~;
            break;
        }
        bool computed;
        uint key = self.prop_key(&computed)!;
        if (self.tok.type == TokenType.COLON) {
            self.next()!;
            uint value = self.binding_element()!;
            self.scratch_push(self.node(NodeTag.PAT_PROP, start.pos, key, value, computed ? PROP_COMPUTED : 0));
        } else {
            if (computed || !self.is_ident_token(start)) return self.unexpected()~;
            uint ident = self.ident_node(start);
            uint dflt = 0;
            if (self.tok.type == TokenType.ASSIGN) {
                self.next()!;
                bool saved = self.no_in;
                self.no_in = false;
                dflt = self.assign_expr()!;
                self.no_in = saved;
            }
            self.scratch_push(self.node(NodeTag.PAT_PROP, start.pos, ident, dflt, PROP_SHORTHAND_PAT));
        }
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RBRACE)!;
    return self.node(NodeTag.OBJECT_PAT, pos, self.scratch_list(mark));
}

// ---- cover grammar ----

// Reinterpret the expression `n` as a pattern in place: an array or object literal becomes an
// ARRAY_PAT / OBJECT_PAT, `a = b` an ASSIGN_PAT, a spread a REST. `binding` selects binding-pattern
// rules (only identifiers as targets) over assignment-pattern rules (any simple target). Already
// converted nodes are accepted unchanged.
fn void? Parser.to_pattern(&self, uint n, bool binding) {
    self.check_stack()!;
    NodeTag tag = self.ast.tags.data[n];
    uint at = self.ast.main_tok.data[n];
    switch (tag) {
        case NodeTag.IDENT:
            if (binding && self.is_paren(n)) return self.fail_at(at, "invalid destructuring target")~;
        case NodeTag.MEMBER:
        case NodeTag.INDEX:
        case NodeTag.PRIVATE_MEMBER:
        case NodeTag.SUPER_MEMBER:
        case NodeTag.SUPER_INDEX:
            if (binding) return self.fail_at(at, "invalid binding pattern")~;
        case NodeTag.ARRAY_PAT:
        case NodeTag.OBJECT_PAT:
        case NodeTag.ASSIGN_PAT:
        case NodeTag.REST:
        case NodeTag.PAT_PROP:
            return;
        case NodeTag.ARRAY:
            if (self.is_paren(n)) return self.fail_at(at, "invalid destructuring target")~;
            self.ast.tags.data[n] = NodeTag.ARRAY_PAT;
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) {
                uint el = self.ast.list_item(list, i);
                if (el == 0) continue;
                if (self.ast.tags.data[el] == NodeTag.SPREAD) {
                    if (i + 1 != count) return self.fail_at(self.ast.main_tok.data[el], "rest element must be last element")~;
                    self.ast.tags.data[el] = NodeTag.REST;
                    self.to_pattern(self.ast.lhs.data[el], binding)!;
                } else {
                    self.to_pattern_element(el, binding)!;
                }
            }
        case NodeTag.OBJECT:
            if (self.is_paren(n)) return self.fail_at(at, "invalid destructuring target")~;
            self.ast.tags.data[n] = NodeTag.OBJECT_PAT;
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) {
                uint p = self.ast.list_item(list, i);
                switch (self.ast.tags.data[p]) {
                    case NodeTag.PROP_INIT:
                        self.ast.tags.data[p] = NodeTag.PAT_PROP;
                        self.to_pattern_element(self.ast.rhs.data[p], binding)!;
                    case NodeTag.PROP_SHORTHAND:
                        self.ast.tags.data[p] = NodeTag.PAT_PROP;
                        self.ast.flags.data[p] = PROP_SHORTHAND_PAT;
                    case NodeTag.PROP_SPREAD:
                        if (i + 1 != count) return self.fail_at(self.ast.main_tok.data[p], "rest element must be last element")~;
                        self.ast.tags.data[p] = NodeTag.REST;
                        uint target = self.ast.lhs.data[p];
                        NodeTag tt = self.ast.tags.data[target];
                        if (tt == NodeTag.ARRAY || tt == NodeTag.OBJECT || tt == NodeTag.ARRAY_PAT || tt == NodeTag.OBJECT_PAT) {
                            return self.fail_at(self.ast.main_tok.data[p], "invalid rest element")~;
                        }
                        self.to_pattern(target, binding)!;
                    default:
                        return self.fail_at(self.ast.main_tok.data[p], "invalid destructuring target")~;
                }
            }
        default:
            return self.fail_at(at, "invalid destructuring target")~;
    }
}

// An element of a pattern: a target with an optional default (`a = 1` written as an assignment).
fn void? Parser.to_pattern_element(&self, uint n, bool binding) {
    if (self.ast.tags.data[n] == NodeTag.ASSIGN && !self.is_paren(n)
        && self.ast.flags.data[n] == op_flag(TokenType.ASSIGN)) {
        self.ast.tags.data[n] = NodeTag.ASSIGN_PAT;
        self.ast.flags.data[n] = 0;
        return self.to_pattern(self.ast.lhs.data[n], binding);
    }
    return self.to_pattern(n, binding);
}

// ---- classes ----

fn uint? Parser.class_decl(&self, bool anonymous_ok = false) {
    uint start = self.tok.pos;
    self.next()!;
    uint name = 0;
    if (self.tok.type != TokenType.EXTENDS && self.tok.type != TokenType.LBRACE) {
        if (!self.is_ident_token(self.tok)) return self.unexpected()~;
        name = self.ident_node(self.tok);
        self.next()!;
    } else if (!anonymous_ok) {
        return self.unexpected()~;
    }
    uint rec = self.class_tail(start)!;
    return self.node(NodeTag.CLASS_DECL, start, name, rec);
}

fn uint? Parser.class_expr(&self) {
    uint start = self.tok.pos;
    self.next()!;
    uint name = 0;
    if (self.tok.type != TokenType.EXTENDS && self.tok.type != TokenType.LBRACE) {
        if (!self.is_ident_token(self.tok)) return self.unexpected()~;
        name = self.ident_node(self.tok);
        self.next()!;
    }
    uint rec = self.class_tail(start)!;
    return self.node(NodeTag.CLASS_EXPR, start, name, rec);
}

// Heritage and body of a class. Class code is strict.
fn uint? Parser.class_tail(&self, uint start) {
    bool saved_strict = self.ctx.strict;
    bool saved_no_in = self.no_in;
    self.ctx.strict = true;
    self.no_in = false;
    uint heritage = 0;
    if (self.tok.type == TokenType.EXTENDS) {
        self.next()!;
        heritage = self.call_expr()!;
    }
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.SEMICOLON) {
            self.next()!;
            continue;
        }
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.class_member(heritage != 0)!);
    }
    self.next()!;
    self.ctx.strict = saved_strict;
    self.no_in = saved_no_in;
    uint rec = self.ast.add_record(CLS_SIZE);
    self.ast.set_field(rec, CLS_HERITAGE, heritage);
    self.ast.set_field(rec, CLS_MEMBERS, self.scratch_list(mark));
    self.ast.set_field(rec, CLS_SRC_START, start);
    self.ast.set_field(rec, CLS_SRC_END, self.prev.end);
    return rec;
}

fn uint? Parser.class_member(&self, bool derived) {
    Token first = self.tok;
    bool is_static = false;
    if (first.type == TokenType.STATIC) {
        TokenType pt = self.peek_type();
        if (pt == TokenType.LBRACE) {
            self.next()!;
            return self.static_block(first.pos);
        }
        if (pt != TokenType.LPAREN && pt != TokenType.ASSIGN && pt != TokenType.SEMICOLON && pt != TokenType.RBRACE) {
            is_static = true;
            self.next()!;
        }
    }
    // `toString` of a method starts after `static`.
    uint start = self.tok.pos;
    bool is_async = false;
    bool is_gen = false;
    char kind_flags = 0;
    if (self.at_word("async") && !self.peek_tok_nl_after_async() && self.modifier_applies(true)) {
        is_async = true;
        self.next()!;
    }
    if (self.tok.type == TokenType.STAR) {
        is_gen = true;
        self.next()!;
    }
    if (!is_async && !is_gen && self.tok.type == TokenType.IDENTIFIER && !self.tok.has_escape
        && (self.at_word("get") || self.at_word("set")) && self.modifier_applies(false)) {
        kind_flags = self.at_word("get") ? MEMBER_GET : MEMBER_SET;
        self.next()!;
    }
    bool computed;
    uint key = self.prop_key(&computed)!;
    char flags = (computed ? PROP_COMPUTED : 0) | (is_static ? MEMBER_STATIC : 0) | kind_flags;
    if (self.tok.type == TokenType.LPAREN || is_async || is_gen || kind_flags != 0) {
        uint fnf = FNF_METHOD | (is_async ? FNF_ASYNC : 0) | (is_gen ? FNF_GENERATOR : 0);
        if (kind_flags == MEMBER_GET) fnf |= FNF_GETTER;
        if (kind_flags == MEMBER_SET) fnf |= FNF_SETTER;
        if (!is_static && !computed && kind_flags == 0 && !is_async && !is_gen
            && self.ast.tags.data[key] == NodeTag.STRING
            && self.ast.atoms.equals(self.ast.lhs.data[key], "constructor")) {
            fnf |= FNF_CTOR;
            if (derived) fnf |= FNF_DERIVED_CTOR;
        }
        uint func = self.method_function(start, fnf, false)!;
        return self.node(NodeTag.CLASS_METHOD, start, key, func, flags);
    }
    // A field, with an optional initialiser.
    uint init = 0;
    if (self.tok.type == TokenType.ASSIGN) {
        self.next()!;
        init = self.field_initializer()!;
    }
    self.semicolon()!;
    return self.node(NodeTag.CLASS_FIELD, start, key, init, flags);
}

// The initialiser expression of a class field: its own function-like context where `arguments`
// is invalid and `await`/`yield` are not operators.
fn uint? Parser.field_initializer(&self) {
    FnCtx saved = self.ctx;
    uint saved_depth = self.cover_depth;
    self.cover_depth = 0;
    self.ctx.is_async = false;
    self.ctx.is_generator = false;
    self.ctx.is_arrow = false;
    self.ctx.in_function = false;
    self.ctx.top_level_await = false;
    self.ctx.in_static_block = false;
    self.ctx.in_field_init = true;
    self.ctx.allow_new_target = true;
    self.ctx.allow_super_property = true;
    self.ctx.allow_super_call = false;
    uint e = self.assign_expr()!;
    self.ctx = saved;
    self.cover_depth = saved_depth;
    return e;
}

fn uint? Parser.static_block(&self, uint pos) {
    FnCtx saved = self.ctx;
    uint saved_depth = self.cover_depth;
    self.cover_depth = 0;
    self.ctx.is_async = false;
    self.ctx.is_generator = false;
    self.ctx.is_arrow = false;
    self.ctx.in_function = false;
    self.ctx.top_level_await = false;
    self.ctx.in_static_block = true;
    self.ctx.in_field_init = false;
    self.ctx.allow_new_target = true;
    self.ctx.allow_super_property = true;
    self.ctx.allow_super_call = false;
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.statement_list_item_in_block()!);
    }
    self.next()!;
    self.ctx = saved;
    self.cover_depth = saved_depth;
    return self.node(NodeTag.STATIC_BLOCK, pos, self.scratch_list(mark));
}
