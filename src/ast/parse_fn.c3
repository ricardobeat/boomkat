// Functions, classes, binding patterns and cover-grammar conversion.
module boomkat::ast;

import boomkat::features;

import boomkat::lexer;
import boomkat::frontendstats;
import boomkat::bytecode;
import boomkat::ast::vec;
import std::time;


// ---- deferred-body index ----
//
// A function body `gen` keeps as a deferred template is parsed with full grammar
// but its nodes are discarded. These flags and the recorded references on its
// stub are what an enclosing compile needs: the resolver marks a binding captured
// when the body references it, and a dynamic scope inside the body reaches every
// function around it.
const uint BODY_HAS_EVAL = 1;
const uint BODY_HAS_WITH = 2;
// The body mentions an identifier spelled with a Unicode escape, so its
// references cannot be matched to a binding by text: the enclosing compile
// has to assume every binding it could reach is captured.
const uint BODY_HAS_ESCAPE = 4;
// Set on a function body's BLOCK node that holds only a stub: `gen` must keep it
// as a template, and the resolver takes its references from the stub's record
// instead of from nodes that are not there.
const char BODY_RECORDED = 0x80;

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
    if (self.tok.type != TokenType.LPAREN && !(self.lex.ts_mode && self.tok.type == TokenType.LT)) {
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
        if (decl) {
            DeclKind dk = self.dv_is_func_scope() ? DeclKind.FUNC : DeclKind.FUNC_BLOCK;
            bool plain = !self.ctx.strict && (fnf & (FNF_ASYNC | FNF_GENERATOR)) == 0;
            self.dv_declare(self.ast.lhs.data[name], dk, self.ast.main_tok.data[name], false, plain);
        }
    } else if (decl && !anonymous_ok) {
        return self.unexpected()~;
    }
    if (self.lex.ts_mode && self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
    uint body_kind = decl ? frontendstats::FS_BODY_DECL
        : (name == 0 ? frontendstats::FS_BODY_UEXPR : frontendstats::FS_BODY_OTHER);
    uint rec = self.function_tail(start, fnf, body_kind)!;
    if (self.ast.field(rec, FN_BODY) == 0) {
        if (!decl) return self.unexpected()~;
        return self.node(NodeTag.EMPTY_STMT, start);
    }
    return self.node(decl ? NodeTag.FUNC_DECL : NodeTag.FUNC_EXPR, start, name, rec);
}

// An object or class method: the parameter list and body, returned as a nameless FUNC_EXPR.
fn uint? Parser.method_function(&self, uint start, uint fnf, bool unused) {
    uint rec = self.function_tail(start, fnf, frontendstats::FS_BODY_OTHER)!;
    return self.node(NodeTag.FUNC_EXPR, start, 0, rec);
}

// Parameters and body of a function whose `(` is the current token. Returns the function record.
fn uint? Parser.function_tail(&self, uint start, uint fnf_in, uint body_kind) {
    if (!features::ASYNC_GENERATORS && (fnf_in & (FNF_ASYNC | FNF_GENERATOR)) != 0) return self.unexpected()~;
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
    uint paren = self.tok.pos;
    sz saved_props = self.ts_param_props.len;
    uint params = self.formal_params()!;
    // The parameter property assignments are made before the body runs, so
    // their nodes come first.
    uint props = self.ts_param_prop_statements(start, saved_props);
    self.ts_param_props.truncate(saved_props);
    if (props != 0 && (fnf & FNF_CTOR) == 0) {
        return self.fail("a parameter property is only allowed in a constructor")~;
    }
    uint header_end = self.prev.pos;
    self.ctx.in_params = false;
    self.ts_annotation()!;
    uint body = 0;
    bool skip_ok = self.defer_bodies
        && (body_kind == frontendstats::FS_BODY_DECL || body_kind == frontendstats::FS_BODY_UEXPR)
        && (fnf & (FNF_ASYNC | FNF_GENERATOR)) == 0
        && !self.is_module && !self.lex.ts_mode && !self.lex.jsx.enabled
        && self.params_are_simple(params);
    $if $feat(FRONTEND_STATS):
        time::Time fs_start = time::now();
        uint fs_nodes = (uint)self.ast.tags.len;
        frontendstats::fs_body_enter();
    $endif
    if (self.lex.ts_mode && self.tok.type != TokenType.LBRACE) {
        self.semicolon()!;
    } else {
        body = self.function_block(&fnf, skip_ok, params,
            body_kind == frontendstats::FS_BODY_UEXPR)!;
    }
    $if $feat(FRONTEND_STATS):
        frontendstats::fs_body_leave(body_kind, (uint)self.ast.tags.len - fs_nodes,
            (ulong)(time::now() - fs_start));
    $endif
    if (props != 0 && body != 0) {
        uint list = self.ast.lhs.data[body];
        self.ast.lhs.data[body] = self.ts_param_prop_body(list, props, (fnf & FNF_DERIVED_CTOR) != 0)!;
    }
    self.ctx = saved;
    self.no_in = saved_no_in;
    self.cover_depth = saved_depth;
    if (self.params_are_simple(params)) fnf |= FNF_SIMPLE_PARAMS;
    uint rec = self.fn_record(fnf, params, body, start, self.prev.end);
    self.ast.set_field(rec, FN_PAREN, paren);
    self.ast.set_field(rec, FN_HEADER_END, header_end);
    return rec;
}

// `( params )`: patterns with optional defaults and a final rest element.
fn uint? Parser.formal_params(&self) {
    self.expect(TokenType.LPAREN)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RPAREN) {
        if (self.lex.ts_mode && self.tok.type == TokenType.THIS) {
            self.next()!;
            self.ts_annotation()!;
            if (self.eat(TokenType.COMMA)!) continue;
            break;
        }
        if (self.tok.type == TokenType.ELLIPSIS) {
            uint pos = self.tok.pos;
            self.next()!;
            uint target = self.binding_target()!;
            self.ts_annotation()!;
            self.scratch_push(self.node(NodeTag.REST, pos, target));
            if (self.tok.type != TokenType.RPAREN) return self.fail("rest parameter must be last formal parameter")~;
            break;
        }
        if (self.lex.ts_mode && self.ts_param_property()) {
            // A parameter property: the parameter is also assigned to the
            // instance, which the constructor does when it runs. The modifier
            // only counts in front of a name.
            Token? pk = self.peek();
            if (catch err = pk) return err~;
            if (pk.type == TokenType.IDENTIFIER) {
                while (self.ts_param_property()) self.next()!;
                if (self.tok.type != TokenType.IDENTIFIER) return self.fail("a parameter property must name a parameter")~;
                self.ts_param_props.push(self.atom(self.tok.str_value));
            }
        }
        self.scratch_push(self.binding_element()!);
        if (self.tok.type != TokenType.COMMA) break;
        self.next()!;
    }
    self.expect(TokenType.RPAREN)!;
    return self.scratch_list(mark);
}

// Whether `fn`'s body was recorded rather than parsed, so `gen` can only compile
// it through its template and the resolver has to read the body index.
fn bool Ast.body_was_recorded(&self, uint fn_node) {
    uint rec = self.rhs.data[fn_node];
    if (rec == 0) return false;
    uint body = self.field(rec, FN_BODY);
    if (body == 0 || self.tags.data[body] != NodeTag.BLOCK) return false;
    return (self.flags.data[body] & BODY_RECORDED) != 0;
}

// Whether a call follows the function body that just closed, so the function is
// the callee `(function () { })()`. `gen` compiles such a callee in place, so
// recording its body would add a second parse of its whole subtree the first time
// it runs, which costs more than the nodes the walk skipped. The decision is made
// with the body's nodes still present; only the grammar after them is in doubt.
fn bool Parser.call_follows(&self) {
    if (self.tok.type == TokenType.LPAREN) return true;
    if (self.tok.type != TokenType.RPAREN) return false;
    // `(function () { })()` and one nesting parenthesis: look past the `)`.
    Token save = self.tok;
    Token save_prev = self.prev;
    // A speculative look-ahead must not latch a lexical fault: the tokens it
    // passes are parsed for real afterwards, and a stale `failed` would abort
    // the body with the wrong error position.
    bool saved_failed = self.failed;
    uint saved_err_pos = self.err_pos;
    uint saved_err_len = self.err_len;
    bool invoked = false;
    uint closes = 0;
    while (closes < 2) {
        closes++;
        if (catch err = self.advance()) break;
        if (self.tok.type == TokenType.LPAREN) { invoked = true; break; }
        if (self.tok.type != TokenType.RPAREN) break;
    }
    self.lex_from(save);
    self.prev = save_prev;
    self.failed = saved_failed;
    self.err_pos = saved_err_pos;
    self.err_len = saved_err_len;
    return invoked;
}

// Put the parser back on `tok`, which a look-ahead advanced past.
fn void Parser.lex_from(&self, Token tok) {
    self.lex.seek_to_token(tok);
    self.has_peek = false;
    self.tok = tok;
    // Re-read the token so the lexer sits after it again. A lexical error here is
    // the body's own to report, at the same offset.
    Token? t = self.lex_one();
    if (catch err = t) {}
}

// `{ directives statements }` of a function body. Sets FNF_USE_STRICT and FNF_STRICT.
fn uint? Parser.function_block(&self, uint* fnf, bool skip_ok = false, uint params = 0, bool callee = false) {
    uint pos = self.tok.pos;
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    AstMark amark = self.ast.mark();
    uint saved_track = self.dv_track;
    bool saved_on = self.dv_on;
    // Every body in a deferred subtree is validated inline: the enclosing
    // recorded body discards its nodes, so the whole-unit Early pass never sees
    // them. Give each body its own scope tree, whether or not its own nodes are
    // kept, and start before the directive prologue so its references count.
    bool track = skip_ok || saved_on;
    uint ref0 = 0;
    if (track) {
        self.dv_on = true;
        self.dv_body_enter(params);
        ref0 = self.dv_ref_base;
    }
    defer {
        self.dv_track = saved_track;
        self.dv_on = saved_on;
    }
    char flags = 0;
    self.directive_prologue(mark, &flags)!;
    if ((flags & PROGRAM_STRICT) != 0) *fnf |= FNF_USE_STRICT;
    // The compiler compiles class code in place, and a body anywhere inside a
    // class may name its private names, which the body's own source cannot show.
    bool defer_body = skip_ok && self.class_depth == 0;
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.statement_list_item_in_block()!);
    }
    if (self.ctx.strict) *fnf |= FNF_STRICT;
    self.next()!;
    // A callee `gen` compiles in place keeps its nodes: recording it would parse
    // the whole subtree a second time on the first call.
    if (defer_body && callee && self.call_follows()) defer_body = false;
    if (track) {
        // Check this body's redeclaration errors, whether or not it is recorded.
        if (!self.dv_body_leave()) return self.fail_at(self.err_pos, "invalid function body")~;
    }
    if (defer_body) {
        // Keep only the references and dynamic-scope facts its enclosing compile
        // needs. The body re-parses this source on first call.
        char body_flags = self.dv_flags;
        if (!self.early.body(self.scratch.data[mark:(sz)self.scratch.len - mark], self.ctx.strict)) {
            return self.fail_at(self.early.err_pos, self.early.error_message())~;
        }
        self.ast.truncate(amark);
        self.scratch.truncate(mark);
        uint nrefs = self.dv_unique_refs(ref0, (uint)self.dv_refs.len - ref0);
        uint at = self.ast.add_record(2 + nrefs);
        self.ast.set_field(at, 0, body_flags);
        self.ast.set_field(at, 1, nrefs);
        for (uint i = 0; i < nrefs; i++) {
            self.ast.set_field(at, 2 + i, self.dv_refs.data[ref0 + i]);
        }
        uint stub = self.node(NodeTag.BLOCK, pos, 0, at);
        self.ast.set_flags(stub, BODY_RECORDED);
        return stub;
    }
    uint block = self.node(NodeTag.BLOCK, pos, self.scratch_list(mark));
    return block;
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
    self.ts_annotation(optional: true)!;
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
                    if (i + 1 != count || (self.ast.flags.data[el] & SPREAD_COMMA) != 0) return self.fail_at(self.ast.main_tok.data[el], "rest element must be last element")~;
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
                        if (i + 1 != count || (self.ast.flags.data[p] & SPREAD_COMMA) != 0) return self.fail_at(self.ast.main_tok.data[p], "rest element must be last element")~;
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

// Whether a class head ends here, so its name is absent: `class {`, `class
// extends B {`, and, in TypeScript, the type parameters and `implements` of an
// anonymous class expression.
fn bool Parser.class_head_unnamed(&self) {
    if (self.tok.type == TokenType.EXTENDS || self.tok.type == TokenType.LBRACE) return true;
    if (!self.lex.ts_mode) return false;
    return self.tok.type == TokenType.LT || self.at_word("implements");
}

fn uint? Parser.class_decl(&self, bool anonymous_ok = false) {
    uint start = self.tok.pos;
    self.next()!;
    uint name = 0;
    if (!self.class_head_unnamed()) {
        if (!self.is_ident_token(self.tok)) return self.unexpected()~;
        name = self.ident_node(self.tok);
        self.next()!;
    } else if (!anonymous_ok) {
        return self.unexpected()~;
    }
    if (name != 0) {
        self.dv_declare(self.ast.lhs.data[name], DeclKind.CLASS, self.ast.main_tok.data[name]);
    }
    uint rec = self.class_tail(start)!;
    return self.node(NodeTag.CLASS_DECL, start, name, rec);
}

fn uint? Parser.class_expr(&self) {
    uint start = self.tok.pos;
    self.next()!;
    uint name = 0;
    if (!self.class_head_unnamed()) {
        if (!self.is_ident_token(self.tok)) return self.unexpected()~;
        name = self.ident_node(self.tok);
        self.next()!;
    }
    uint rec = self.class_tail(start)!;
    return self.node(NodeTag.CLASS_EXPR, start, name, rec);
}

// A class's heritage and computed keys are strict code (§11.2.2) evaluated in
// the enclosing frame, whose strictness the VM reads from its function. In
// sloppy code the expression `e` (nodes `first` .. `e`) becomes `(() => e)()`
// with a strict arrow, which evaluates it in a strict frame and sees the same
// `this`, `arguments`, `new.target` and `super`. An expression holding `yield`
// or `await` cannot move into an arrow and stays inline.
fn uint Parser.strict_thunk(&self, uint first, uint e) {
    if (!self.class_in_sloppy) return e;
    bool needed = false;
    for (uint i = first; i <= e; i++) {
        switch (self.ast.tags.data[i]) {
            case NodeTag.YIELD:
            case NodeTag.YIELD_STAR:
            case NodeTag.AWAIT:
                return e;
            case NodeTag.ASSIGN:
            case NodeTag.UPDATE_PRE:
            case NodeTag.UPDATE_POST:
            case NodeTag.UNARY:
            case NodeTag.CALL:
            case NodeTag.NEW:
            case NodeTag.TAGGED_TEMPLATE:
                needed = true;
            default:
                break;
        }
    }
    // Without these nothing in the expression depends on strictness.
    if (!needed) return e;
    uint pos = self.ast.main_tok.data[e];
    uint params = self.ast.add_list({});
    uint rec = self.fn_record(FNF_EXPR_BODY | FNF_STRICT | FNF_SIMPLE_PARAMS, params, e, pos, self.prev.end);
    self.ast.set_field(rec, FN_BODY_START, pos);
    self.ast.set_field(rec, FN_HEADER_END, pos);
    uint arrow = self.node(NodeTag.ARROW, pos, 0, rec);
    return self.node(NodeTag.CALL, pos, arrow, self.ast.add_list({}));
}

// Heritage and body of a class. Class code is strict.
fn uint? Parser.class_tail(&self, uint start) {
    bool saved_strict = self.ctx.strict;
    bool saved_no_in = self.no_in;
    bool saved_sloppy = self.class_in_sloppy;
    uint saved_track = self.dv_track;
    self.dv_track = 0;   // a class body is strict and eager: its decls do not bind in a deferred body
    defer self.dv_track = saved_track;
    self.class_in_sloppy = !saved_strict;
    defer self.class_in_sloppy = saved_sloppy;
    self.class_depth++;
    defer self.class_depth--;
    self.ctx.strict = true;
    self.no_in = false;
    uint heritage = 0;
    if (self.lex.ts_mode && self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
    if (self.tok.type == TokenType.EXTENDS) {
        self.next()!;
        uint first = self.ast.node_count();
        heritage = self.call_expr()!;
        if (self.is_bare_arrow(heritage)) return self.fail_at(self.ast.main_tok.data[heritage], "an arrow function is not a class heritage")~;
        heritage = self.strict_thunk(first, heritage);
        // The type arguments of the base class, `extends Base<T>`, have no
        // runtime effect.
        if (self.lex.ts_mode && self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
    }
    if (self.lex.ts_mode && self.at_word("implements")) {
        self.next()!;
        for (;;) {
            self.ts_skip_type()!;
            if (!(self.eat(TokenType.COMMA)!)) break;
        }
    }
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.SEMICOLON) {
            self.next()!;
            continue;
        }
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        uint member = self.class_member(heritage != 0)!;
        if (self.ast.tags.data[member] != NodeTag.EMPTY_STMT) self.scratch_push(member);
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
    self.ts_class_modifiers()!;
    if (self.lex.ts_mode && self.ts_index_signature()) return self.node(NodeTag.EMPTY_STMT, self.prev.pos);
    Token first = self.tok;
    bool is_static = false;
    if (first.type == TokenType.STATIC) {
        TokenType pt = self.peek_type();
        if (pt == TokenType.LBRACE) {
            if (first.has_escape) return self.fail("keyword must not contain escaped characters")~;
            self.next()!;
            return self.static_block(first.pos);
        }
        // TS `static<T>()` is a generic method named `static`.
        if (pt != TokenType.LPAREN && pt != TokenType.ASSIGN && pt != TokenType.SEMICOLON && pt != TokenType.RBRACE
            && !(self.lex.ts_mode && pt == TokenType.LT)) {
            if (first.has_escape) return self.fail("keyword must not contain escaped characters")~;
            is_static = true;
            self.next()!;
        }
    }
    self.ts_class_modifiers()!;
    if (self.lex.ts_mode && self.ts_index_signature()) return self.node(NodeTag.EMPTY_STMT, self.prev.pos);
    if (self.lex.ts_mode && self.at_word("accessor") && self.modifier_applies(false)) {
        return self.fail("auto-accessors are not supported")~;
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
    uint key_first = self.ast.node_count();
    uint key = self.prop_key(&computed)!;
    if (computed) key = self.strict_thunk(key_first, key);
    char flags = (computed ? PROP_COMPUTED : 0) | (is_static ? MEMBER_STATIC : 0) | kind_flags;
    if (self.lex.ts_mode && self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
    if (self.lex.ts_mode && self.tok.type == TokenType.QUESTION) self.next()!;
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
        if (self.ast.field(self.ast.rhs.data[func], FN_BODY) == 0) return self.node(NodeTag.EMPTY_STMT, start);
        return self.node(NodeTag.CLASS_METHOD, start, key, func, flags);
    }
    self.ts_annotation(definite: true)!;
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
    uint brace = self.tok.pos;
    self.expect(TokenType.LBRACE)!;
    uint mark = self.scratch_mark();
    while (self.tok.type != TokenType.RBRACE) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        self.scratch_push(self.statement_list_item_in_block()!);
    }
    self.next()!;
    self.ctx = saved;
    self.cover_depth = saved_depth;
    return self.node(NodeTag.STATIC_BLOCK, pos, self.scratch_list(mark), brace);
}
