module boomkat::ast @feat(!NO_TYPESCRIPT);

import boomkat::lexer;

fn void? Parser.ts_skip_type(&self, bool expression = false) {
    int paren   = 0;
    int bracket = 0;
    int brace   = 0;
    int angle   = 0;
    bool consumed_any = false;
    bool paren_has_arrow  = false;
    bool last_group_had_arrow = false;
    bool group_seen_first = false;
    bool top_group_first_is_group = false;
    TokenType prev_tt = TokenType.EOF_TOKEN;
    char[] prev_str = (char[])"";
    bool just_closed_obj = false;
    // The conditional types still open at depth 0: those that said `extends`
    // and await their `?`, and those that said `?` and await their `:`.
    int awaiting_question = 0;
    int awaiting_colon = 0;

    for (;;) {
        TokenType tt = self.tok.type;
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        int depth = paren + bracket + brace + angle;

        if (just_closed_obj && depth == 0) {
            if (tt != TokenType.BIT_OR && tt != TokenType.BIT_AND
                && tt != TokenType.EXTENDS && tt != TokenType.QUESTION
                && tt != TokenType.COLON && tt != TokenType.LBRACKET) {
                return;
            }
            just_closed_obj = false;
        }

        if (depth == 0) {
            if (expression && consumed_any && ts_token_completes_type(prev_tt)) {
                switch (tt) {
                    case PLUS: case MINUS: case STAR: case SLASH: case PERCENT: case STARSTAR:
                    case SHL: case SHR: case USHR: case EQ: case NE: case SEQ: case SNE:
                    case LOG_AND: case LOG_OR: case NULLISH:
                        return;
                    case LPAREN:
                        // `readonly (A | B)[]` keeps the parenthesis, while the
                        // `(y)` of `x as T (y)` is a call on the assertion.
                        if (!(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) return;
                        break;
                    case QUESTION:
                        // `a === b as T ? c : d` asks a question; a conditional
                        // type already said `extends` before its own `?`.
                        if (awaiting_question == 0) return;
                        break;
                    default: break;
                }
            }
            switch (tt) {
                case TokenType.EOF_TOKEN:
                case TokenType.SEMICOLON:
                case TokenType.COMMA:
                case TokenType.RPAREN:
                case TokenType.RBRACKET:
                case TokenType.RBRACE:
                case TokenType.ASSIGN:
                    return;
                case TokenType.COLON:
                    // An assertion in an expression ends at the `:` of the
                    // conditional whose branch it is, `a ? b as T : c`, unless
                    // a conditional type of its own awaits that `:`.
                    if (expression && awaiting_colon == 0) return;
                    break;
                case TokenType.ARROW:
                    if (prev_tt == TokenType.RPAREN && last_group_had_arrow) return;
                    if (prev_tt == TokenType.RPAREN) break;
                    return;
                default:
                    break;
            }
            if (tt == TokenType.LBRACE && consumed_any && ts_token_completes_type(prev_tt)
                && !(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) {
                return;
            }
            if (self.tok.nl_before && consumed_any && ts_token_completes_type(prev_tt)
                && !(prev_tt == TokenType.IDENTIFIER && ts_ident_is_type_operator(prev_str))) {
                if (tt != TokenType.BIT_OR && tt != TokenType.BIT_AND
                    && tt != TokenType.EXTENDS && tt != TokenType.QUESTION
                    && tt != TokenType.COLON && tt != TokenType.ARROW
                    && tt != TokenType.LBRACKET && tt != TokenType.LT
                    && tt != TokenType.DOT) {
                    return;
                }
            }
        }
        if (self.lex.ts_mode && tt == TokenType.IMPORT) {
            Token _imp = self.ts_advance()!;
            continue;
        }
        if (depth == 0 && ts_token_stops_type(tt)) {
            return;
        }

        Token skip_tok = self.ts_advance()!;
        consumed_any = true;
        if (depth == 0) {
            switch (tt) {
                case TokenType.EXTENDS:
                    awaiting_question++;
                case TokenType.QUESTION:
                    if (awaiting_question > 0) {
                        awaiting_question--;
                        awaiting_colon++;
                    }
                case TokenType.COLON:
                    if (awaiting_colon > 0) awaiting_colon--;
                default:
            }
        }
        if (paren == 1 && !group_seen_first && tt != TokenType.RPAREN) {
            group_seen_first = true;
            if (tt == TokenType.LPAREN || tt == TokenType.LT) {
                top_group_first_is_group = true;
            }
        }

        switch (tt) {
            case TokenType.LPAREN:
                if (paren == 0) paren_has_arrow = false;
                paren++;
                break;
            case TokenType.RPAREN:
                if (paren > 0) paren--;
                if (paren == 0) last_group_had_arrow = paren_has_arrow;
                break;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            case TokenType.LT:       angle++;
            case TokenType.GT:       if (angle > 0) angle--;
            case TokenType.GE:       if (angle > 0) angle--;  // `>=` at end of generic like `T=>`
            case TokenType.SHR:      if (angle >= 2) { angle -= 2; } else if (angle == 1) angle--;
            case TokenType.USHR:     if (angle >= 3) { angle -= 3; } else if (angle > 0) angle = 0;
            case TokenType.ARROW:
                if (paren == 1 && top_group_first_is_group) paren_has_arrow = true;
                break;
            case TokenType.EOF_TOKEN:
                return;  // safety net; loop guard above should have exited
            default:
                break;
        }
        prev_tt = tt;
        prev_str = skip_tok.str_value;
        if (tt == TokenType.RBRACE && brace == 0 && paren == 0 && bracket == 0 && angle == 0) {
            just_closed_obj = true;
        }
    }
}

// Skip a `<...>` list, generic parameters or type arguments. `type_args` makes
// the list be checked for tokens that no type argument list holds.
fn void? Parser.ts_skip_generic_params(&self, bool type_args = false) {
    Token _skip_open = self.expect(TokenType.LT)!;
    int angle = 1;
    int paren = 0;
    int bracket = 0;
    int brace = 0;

    while (angle > 0) {
        TokenType tt = self.tok.type;
        if (tt == TokenType.EOF_TOKEN) {
            return self.fail("unterminated type parameter list")~;
        }
        if (tt == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        // A type argument list holds types and nothing else, so a token no
        // type holds rules it out. Without this, `a < b && c > (d)` reads as
        // the call `a<b && c>(d)`.
        if (type_args && angle == 1 && paren == 0 && bracket == 0 && brace == 0
            && ts_token_ends_type_args(tt)) {
            return self.fail_at(self.tok.pos, "not a type argument list")~;
        }
        Token _skip = self.ts_advance()!;
        switch (tt) {
            case TokenType.LT:       angle++;
            case TokenType.GT:       angle--;
            case TokenType.GE:       angle--;
            case TokenType.SHR:      angle -= 2;
            case TokenType.USHR:     angle -= 3;
            case TokenType.LPAREN:   paren++;
            case TokenType.RPAREN:   if (paren > 0) paren--;
            case TokenType.LBRACKET: bracket++;
            case TokenType.RBRACKET: if (bracket > 0) bracket--;
            case TokenType.LBRACE:   brace++;
            case TokenType.RBRACE:   if (brace > 0) brace--;
            default: break;
        }
        if (angle < 0) angle = 0;
    }
}

fn Token? Parser.ts_advance(&self) {
    Token token = self.tok;
    self.next()!;
    return token;
}

fn void? Parser.ts_skip_template(&self) {
    for (;;) {
        self.next()!;
        self.ts_skip_type()!;
        if (self.tok.type != TokenType.RBRACE) return self.unexpected()~;
        self.rescan_template()!;
        if (self.tok.type == TokenType.TEMPLATE_TAIL) {
            self.next()!;
            return;
        }
        if (self.tok.type != TokenType.TEMPLATE_MIDDLE) return self.unexpected()~;
    }
}

fn void? Parser.ts_annotation(&self, bool optional = false, bool definite = false) {
    if (!self.lex.ts_mode) return;
    if ((optional && self.tok.type == TokenType.QUESTION)
        || (definite && self.tok.type == TokenType.LOG_NOT)) self.next()!;
    if (self.tok.type == TokenType.COLON) {
        self.next()!;
        self.ts_skip_type()!;
    }
}

fn void? Parser.ts_skip_body(&self) {
    self.expect(TokenType.LBRACE)!;
    uint depth = 1;
    while (depth != 0) {
        if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
        if (self.tok.type == TokenType.TEMPLATE_HEAD) {
            self.ts_skip_template()!;
            continue;
        }
        if (self.tok.type == TokenType.LBRACE) depth++;
        if (self.tok.type == TokenType.RBRACE) depth--;
        self.next()!;
    }
}

// `<` is also a comparison. Speculation consumes only erased tokens and restores the cursor.
fn bool Parser.ts_type_arguments(&self) {
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_skip_generic_params(true)) {
        if (self.tok.type == TokenType.LPAREN || self.tok.type == TokenType.DOT
            || self.tok.type == TokenType.TEMPLATE_HEAD || self.tok.is_template
            || self.tok.type == TokenType.SEMICOLON || self.tok.type == TokenType.RPAREN
            || self.tok.type == TokenType.COMMA || self.tok.type == TokenType.LBRACE) return true;
    }
    self.rewind(&saved, &lexer_saved);
    return false;
}

// A parameter property modifier: `public`, `private`, `protected`, `readonly`
// or `override`. The modifier is type-only, but the parameter is also assigned
// to the instance.
fn bool Parser.ts_param_property(&self) {
    if (!self.lex.ts_mode) return false;
    Token t = self.tok;
    if (t.type == TokenType.PUBLIC || t.type == TokenType.PRIVATE || t.type == TokenType.PROTECTED) return true;
    if (t.type != TokenType.IDENTIFIER || t.has_escape) return false;
    return ident_is(t.str_value, "public") || ident_is(t.str_value, "private")
        || ident_is(t.str_value, "protected") || ident_is(t.str_value, "readonly")
        || ident_is(t.str_value, "override");
}

// The `this.x = x;` statements of a constructor's parameter properties, from
// the names collected after index `from`.
fn uint Parser.ts_param_prop_statements(&self, uint pos, sz from) {
    sz n = self.ts_param_props.len;
    if (n <= from) return 0;
    uint mark = self.scratch_mark();
    for (sz i = from; i < n; i++) {
        uint name = self.ts_param_props.data[i];
        uint member = self.node(NodeTag.MEMBER, pos, self.node(NodeTag.THIS, pos), name);
        uint value = self.node(NodeTag.IDENT, pos, name);
        uint assign = self.node(NodeTag.ASSIGN, pos, member, value, op_flag(TokenType.ASSIGN));
        self.scratch_push(self.node(NodeTag.EXPR_STMT, pos, assign));
    }
    return self.scratch_list(mark);
}

// The statement list of a constructor's body with its parameter property
// assignments `props` added: after the prologue, and in a derived class after
// the super() call, which must then be a statement of the body itself, as
// TypeScript requires.
fn uint? Parser.ts_param_prop_body(&self, uint list, uint props, bool derived) {
    uint count = self.ast.list_len(list);
    uint at = 0;
    while (at < count && self.ast.tags.data[self.ast.list_item(list, at)] == NodeTag.DIRECTIVE) at++;
    if (derived) {
        uint i = at;
        for (; i < count; i++) {
            uint stmt = self.ast.list_item(list, i);
            if (self.ast.tags.data[stmt] != NodeTag.EXPR_STMT) continue;
            if (self.ast.tags.data[self.ast.lhs.data[stmt]] == NodeTag.SUPER_CALL) break;
        }
        if (i == count) {
            return self.fail("a constructor with parameter properties must call super() as a statement of its body")~;
        }
        at = i + 1;
    }
    uint mark = self.scratch_mark();
    for (uint i = 0; i < at; i++) self.scratch_push(self.ast.list_item(list, i));
    for (uint i = 0; i < self.ast.list_len(props); i++) self.scratch_push(self.ast.list_item(props, i));
    for (uint i = at; i < count; i++) self.scratch_push(self.ast.list_item(list, i));
    return self.scratch_list(mark);
}

// The variable and the immediately invoked function that hold a TypeScript
// object: `var N = (function (P) { ...; return P; })(N || (N = {}))`. The
// argument reuses the object a previous declaration of the same name made,
// so that an enum and a namespace of that name share it.
fn uint Parser.ts_object_var(&self, uint name, uint param, uint body, uint pos) {
    uint call = self.ts_object_call(name, param, body, pos);
    uint decl = self.node(NodeTag.DECLARATOR, pos, self.node(NodeTag.IDENT, pos, name), call);
    return self.node(NodeTag.VAR_DECL, pos, self.ast.add_list({ decl }), 0, VAR_KIND_VAR);
}

// A function expression the parser makes up, with simple parameters and the
// block `body`.
fn uint Parser.ts_function(&self, uint params, uint body, uint pos) {
    uint rec = self.fn_record(FNF_SIMPLE_PARAMS, params, body, pos, pos);
    self.ast.set_field(rec, FN_PAREN, pos);
    self.ast.set_field(rec, FN_HEADER_END, pos);
    self.ast.set_field(rec, FN_BODY_START, pos);
    return self.node(NodeTag.FUNC_EXPR, pos, 0, rec);
}

// The call that fills a TypeScript object: `(function (P) { ...; return P; })(N || (N = {}))`.
fn uint Parser.ts_object_call(&self, uint name, uint param, uint body, uint pos) {
    uint func = self.ts_function(self.ast.add_list({ self.node(NodeTag.IDENT, pos, param) }), body, pos);
    uint empty = self.node(NodeTag.OBJECT, pos, self.ast.add_list({}));
    uint fallback = self.node(NodeTag.ASSIGN, pos, self.node(NodeTag.IDENT, pos, name),
        empty, op_flag(TokenType.ASSIGN));
    uint arg = self.node(NodeTag.LOGICAL, pos, self.node(NodeTag.IDENT, pos, name),
        fallback, op_flag(TokenType.LOG_OR));
    return self.node(NodeTag.CALL, pos, func, self.ast.add_list({ arg }));
}

// The call that fills an object a name is already bound to, without declaring a
// variable of its own. A namespace that merges with a class or a function of
// the same name fills that binding instead.
fn uint Parser.ts_object_merge(&self, uint name, uint param, uint body, uint pos) {
    uint call = self.ts_object_call(name, param, body, pos);
    return self.node(NodeTag.EXPR_STMT, pos, call);
}

// ---- the names a TypeScript scope declares ----

// Open a TypeScript scope: the names it declares are kept apart from those of
// the scope around it. Returns the mark `ts_scope_pop` takes.
fn uint Parser.ts_scope_push(&self) {
    return (uint)self.ts_scope_names.len;
}

// Close the scope opened at `mark`.
fn void Parser.ts_scope_pop(&self, uint mark) {
    self.ts_scope_names.truncate(mark);
}

// Whether the current scope declares `name`.
fn bool Parser.ts_scope_has(&self, uint name) {
    for (sz i = 0; i < self.ts_scope_names.len; i++) {
        if (self.ts_scope_names.data[i] == name) return true;
    }
    return false;
}

// The names a statement declares in the scope that holds it.
fn void Parser.ts_record_decl(&self, uint stmt) {
    if (!self.lex.ts_mode) return;
    uint node = stmt;
    if (self.ast.tags.data[node] == NodeTag.EXPORT_DECL) node = self.ast.lhs.data[node];
    switch (self.ast.tags.data[node]) {
        case NodeTag.CLASS_DECL:
        case NodeTag.FUNC_DECL: {
            uint ident = self.ast.lhs.data[node];
            if (ident != 0) self.ts_scope_names.push(self.ast.lhs.data[ident]);
        }
        case NodeTag.VAR_DECL: {
            uint list = self.ast.lhs.data[node];
            for (uint i = 0; i < self.ast.list_len(list); i++) {
                uint target = self.ast.lhs.data[self.ast.list_item(list, i)];
                if (self.ast.tags.data[target] != NodeTag.IDENT) continue;
                self.ts_scope_names.push(self.ast.lhs.data[target]);
            }
        }
        default:
    }
}

// Drop the import specifiers whose local name this module also declares. Only
// a type may share a name that way: the import is elided in the output, so the
// binding it would declare must not clash with the declaration.
fn void Parser.ts_elide_shadowed_imports(&self, uint mark) {
    if (!self.lex.ts_mode || !self.is_module) return;
    uint count = (uint)self.scratch.len - mark;
    for (uint i = 0; i < count; i++) {
        uint decl = self.scratch.data[mark + i];
        if (self.ast.tags.data[decl] == NodeTag.EXPORT_DECL) decl = self.ast.lhs.data[decl];
        if (self.ast.tags.data[decl] != NodeTag.IMPORT_DECL) continue;
        uint specs = self.ast.rhs.data[decl];
        uint scount = self.ast.list_len(specs);
        uint keep = self.scratch_mark();
        bool dropped = false;
        for (uint j = 0; j < scount; j++) {
            uint spec = self.ast.list_item(specs, j);
            uint local = self.ast.rhs.data[spec];
            if (local != 0 && self.ts_scope_has(self.ast.lhs.data[local])) {
                dropped = true;
                continue;
            }
            self.scratch_push(spec);
        }
        if (dropped) {
            self.ast.rhs.data[decl] = self.scratch_list(keep);
        } else {
            self.scratch.truncate(keep);
        }
    }
}

// Whether a namespace of this name merges with a class, a function or an enum
// of the same name declared before it in the same scope. TypeScript rejects a
// namespace placed before the class or function it merges with, and an enum
// merges either way round, so only the names declared already matter.
fn bool Parser.ts_merged_name(&self, uint name) {
    return self.ts_scope_has(name);
}


// A statement that only TypeScript has and that has a runtime effect: an enum.
// Returns 0 when the current token does not start one, leaving the token where
// it was. Only a module's top level may export such a statement.
fn uint? Parser.ts_statement(&self, uint pos, bool top_level) {
    if (!self.lex.ts_mode) return 0;
    self.ts_reject_module_namespace()!;
    uint name;
    if (self.tok.type == TokenType.ENUM) return self.ts_enum(pos, &name);
    if (self.tok.type == TokenType.CONST) {
        Token? pk = self.peek();
        if (catch err = pk) return err~;
        if (pk.type == TokenType.ENUM) return self.ts_enum(pos, &name);
    }
    if (top_level && self.ts_namespace_ahead()) {
        uint decl = self.ts_namespace(pos, &name)!;
        return decl;
    }
    if (top_level && self.is_module && self.tok.type == TokenType.EXPORT) {
        Token? pk = self.peek();
        if (catch err = pk) return err~;
        if (pk.type == TokenType.ENUM) {
            self.next()!;
            uint decl = self.ts_enum(pos, &name)!;
            return self.ts_export(pos, decl, name);
        }
        if (self.is_word(pk, "namespace") || self.is_word(pk, "module")) {
            self.next()!;
            self.ts_reject_module_namespace()!;
            uint decl = self.ts_namespace(pos, &name)!;
            if (self.ast.tags.data[decl] == NodeTag.EMPTY_STMT) return decl;
            return self.ts_export(pos, decl, name);
        }
        if (pk.type == TokenType.CONST) {
            // `export const enum E {}` or `export const x = 1`.
            Parser saved = *self;
            Lexer lexer_saved = *self.lex;
            self.next()!;
            self.next()!;
            if (self.tok.type == TokenType.ENUM) {
                uint decl = self.ts_enum(pos, &name)!;
                return self.ts_export(pos, decl, name);
            }
            self.rewind(&saved, &lexer_saved);
        }
    }
    return 0;
}

// The export of a TypeScript declaration that has a runtime effect. A name
// that is exported already keeps the export it has.
fn uint Parser.ts_export(&self, uint pos, uint decl, uint name) {
    for (sz i = 0; i < self.ts_exports.len; i++) {
        if (self.ts_exports.data[i] == name) return decl;
    }
    self.ts_exports.push(name);
    return self.node(NodeTag.EXPORT_DECL, pos, decl);
}

fn bool? Parser.ts_erase_statement(&self, bool in_namespace = false) {
    if (!self.lex.ts_mode) return false;
    self.ts_erased_name = 0;
    uint pos = self.tok.pos;
    self.ts_reject_module_namespace()!;
    if (self.tok.type == TokenType.ENUM) return self.fail("'enum' is not supported (not erasable syntax)")~;
    if (self.tok.type == TokenType.IMPORT && self.peek_type() == TokenType.IDENTIFIER) {
        Token next = self.peek()!;
        if (self.is_word(next, "type") && !next.nl_before) {
            self.next()!;
            self.next()!;
            self.ts_erase_import_export()!;
            return true;
        }
    }
    if (self.tok.type == TokenType.EXPORT) {
        Token next = self.peek()!;
        if (next.type == TokenType.DEFAULT) {
            Parser saved = *self;
            Lexer lexer_saved = *self.lex;
            self.next()!;
            self.next()!;
            if (self.at_word("interface")) return self.ts_erase_statement(in_namespace);
            self.rewind(&saved, &lexer_saved);
        }
        if (self.is_word(next, "type") || self.is_word(next, "interface")
            || self.is_word(next, "declare") || self.is_word(next, "namespace")) {
            self.next()!;
            if (self.at_word("type") && (self.peek_type() == TokenType.LBRACE || self.peek_type() == TokenType.STAR)) {
                self.next()!;
                self.ts_erase_import_export()!;
                return true;
            }
            return self.ts_erase_statement(in_namespace);
        }
    }
    bool iface = self.at_word("interface");
    bool alias_decl = self.at_word("type");
    bool namespace_decl = self.at_word("namespace");
    if (iface || alias_decl || namespace_decl) {
        Token next = self.peek()!;
        if (next.type != TokenType.IDENTIFIER || next.nl_before) return false;
        uint name = self.atom(next.str_value);
        self.next()!;
        self.next()!;
        if (namespace_decl) {
            while (self.eat(TokenType.DOT)!) self.expect(TokenType.IDENTIFIER)!;
            self.expect(TokenType.LBRACE)!;
            while (self.tok.type != TokenType.RBRACE) {
                if (self.eat(TokenType.SEMICOLON)!) continue;
                if (!(self.ts_erase_statement(true)!)) return self.fail_at(pos, "'namespace' is not supported (not erasable syntax)")~;
            }
            self.next()!;
        } else {
            if (self.tok.type == TokenType.LT) self.ts_skip_generic_params()!;
            if (iface) {
                if (self.eat(TokenType.EXTENDS)!) {
                    for (;;) {
                        self.ts_skip_type()!;
                        if (!(self.eat(TokenType.COMMA)!)) break;
                    }
                }
                self.ts_skip_body()!;
            } else {
                self.expect(TokenType.ASSIGN)!;
                self.ts_skip_type()!;
            }
        }
        self.eat(TokenType.SEMICOLON)!;
        self.ts_erased_name = name;
        return true;
    }
    if (self.at_word("declare")) {
        Token next = self.peek()!;
        if (next.nl_before) return false;
        if (in_namespace && !self.is_word(next, "namespace") && !self.is_word(next, "module")) return false;
        self.next()!;
        self.ts_reject_module_namespace()!;
        if (in_namespace) return self.ts_erase_statement(true);
        bool body = self.tok.type == TokenType.CLASS || self.at_word("interface")
            || self.tok.type == TokenType.ENUM || self.at_word("namespace")
            || self.at_word("module") || self.at_word("global") || self.at_word("abstract");
        uint depth = 0;
        TokenType prev = self.tok.type;
        while (self.tok.type != TokenType.EOF_TOKEN) {
            TokenType tt = self.tok.type;
            if (depth == 0) {
                if (self.eat(TokenType.SEMICOLON)!) return true;
                if (tt == TokenType.LBRACE && body) {
                    self.ts_skip_body()!;
                    self.eat(TokenType.SEMICOLON)!;
                    return true;
                }
                if (self.tok.nl_before && ts_token_completes_type(prev)) return true;
            }
            if (tt == TokenType.TEMPLATE_HEAD) { self.ts_skip_template()!; continue; }
            if (tt == TokenType.LPAREN || tt == TokenType.LBRACKET || tt == TokenType.LBRACE || tt == TokenType.LT) depth++;
            if (tt == TokenType.RPAREN || tt == TokenType.RBRACKET || tt == TokenType.RBRACE || tt == TokenType.GT) {
                if (depth == 0) return true;
                depth--;
            }
            prev = tt;
            self.next()!;
        }
        return true;
    }
    if (self.at_word("abstract") && self.peek_type() == TokenType.CLASS) self.next()!;
    // An ambient module declaration, `module "name" { ... }`, has no runtime
    // effect of its own.
    if (self.ts_ambient_module_ahead()) {
        self.next()!;
        self.next()!;
        self.expect(TokenType.LBRACE)!;
        while (self.tok.type != TokenType.RBRACE) {
            if (self.tok.type == TokenType.EOF_TOKEN) return self.unexpected()~;
            if (self.eat(TokenType.SEMICOLON)!) continue;
            if (!(self.ts_erase_statement(true)!)) return self.fail_at(pos, "'module' is not supported (not erasable syntax)")~;
        }
        self.next()!;
        self.eat(TokenType.SEMICOLON)!;
        return true;
    }
    return false;
}

fn void? Parser.ts_erase_import_export(&self) {
    uint depth = 0;
    while (self.tok.type != TokenType.EOF_TOKEN) {
        TokenType tt = self.tok.type;
        if (depth == 0) {
            if (self.eat(TokenType.SEMICOLON)!) return;
            if (self.tok.nl_before && tt != TokenType.COMMA && !self.at_word("from")
                && tt != TokenType.STRING) return;
        }
        if (tt == TokenType.LBRACE || tt == TokenType.LPAREN || tt == TokenType.LBRACKET) depth++;
        if (tt == TokenType.RBRACE || tt == TokenType.RPAREN || tt == TokenType.RBRACKET) {
            if (depth == 0) return;
            depth--;
        }
        self.next()!;
    }
}

fn bool Parser.ts_index_signature(&self) {
    if (self.tok.type != TokenType.LBRACKET) return false;
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_read_index_signature()) return true;
    self.rewind(&saved, &lexer_saved);
    return false;
}

fn void? Parser.ts_read_index_signature(&self) {
    self.next()!;
    self.expect(TokenType.IDENTIFIER)!;
    self.expect(TokenType.COLON)!;
    self.ts_skip_type()!;
    self.expect(TokenType.RBRACKET)!;
    self.expect(TokenType.COLON)!;
    self.ts_skip_type()!;
    self.semicolon()!;
}

fn void Parser.ts_arrow_return_annotation(&self) {
    if (!self.lex.ts_mode || self.tok.type != TokenType.COLON) return;
    Parser saved = *self;
    Lexer lexer_saved = *self.lex;
    if (try self.ts_annotation()) {
        if (self.tok.type == TokenType.ARROW) return;
    }
    self.rewind(&saved, &lexer_saved);
}

fn void? Parser.ts_class_modifiers(&self) {
    while (self.lex.ts_mode && (self.at_word("public") || self.at_word("private")
        || self.at_word("protected") || self.at_word("readonly") || self.at_word("override")
        || self.at_word("abstract") || self.at_word("declare"))) {
        TokenType next = self.peek_type();
        if (next == TokenType.LPAREN || next == TokenType.LT || next == TokenType.COLON || next == TokenType.ASSIGN
            || next == TokenType.SEMICOLON || next == TokenType.RBRACE) break;
        self.next()!;
    }
}

fn bool ts_token_completes_type(TokenType tt) @inline {
    switch (tt) {
        case TokenType.IDENTIFIER:
        case TokenType.STRING:
        case TokenType.NUMBER:
        case TokenType.BIGINT:
        case TokenType.TEMPLATE:
        case TokenType.RPAREN:
        case TokenType.RBRACKET:
        case TokenType.RBRACE:
        case TokenType.GT:
        case TokenType.GE:
        case TokenType.SHR:
        case TokenType.USHR:
        case TokenType.THIS:
        case TokenType.VOID:
            return true;
        default:
            return false;
    }
}

fn bool ts_ident_is_type_operator(char[] name) @inline {
    return ident_is(name, "keyof") || ident_is(name, "typeof")
        || ident_is(name, "infer") || ident_is(name, "as")
        || ident_is(name, "satisfies") || ident_is(name, "readonly")
        || ident_is(name, "is") || ident_is(name, "asserts")
        || ident_is(name, "abstract");
}

// A token that cannot stand in a type argument list, so a `<` that reaches one
// before its closing `>` does not open one. The list's own separators and the
// tokens of conditional, union and function types are not here.
fn bool ts_token_ends_type_args(TokenType tt) {
    switch (tt) {
        case TokenType.SEMICOLON:
        case TokenType.LOG_AND:
        case TokenType.LOG_OR:
        case TokenType.NULLISH:
        case TokenType.ASSIGN:
        case TokenType.RPAREN:
        case TokenType.RBRACKET:
        case TokenType.RBRACE:
        case TokenType.STAR:
        case TokenType.SLASH:
        case TokenType.PERCENT:
        case TokenType.EQ:
        case TokenType.NE:
        case TokenType.SEQ:
        case TokenType.SNE:
        case TokenType.LE:
        case TokenType.GE:
        case TokenType.INC:
        case TokenType.DEC:
        case TokenType.INSTANCEOF:
            return true;
        default:
            return ts_token_stops_type(tt);
    }
}

fn bool ts_token_stops_type(TokenType tt) {
    switch (tt) {
        case TokenType.FUNCTION:
        case TokenType.IF:
        case TokenType.ELSE:
        case TokenType.FOR:
        case TokenType.WHILE:
        case TokenType.DO:
        case TokenType.SWITCH:
        case TokenType.CASE:
        case TokenType.DEFAULT:
        case TokenType.BREAK:
        case TokenType.CONTINUE:
        case TokenType.RETURN:
        case TokenType.TRY:
        case TokenType.CATCH:
        case TokenType.FINALLY:
        case TokenType.THROW:
        case TokenType.DELETE:
        case TokenType.CLASS:
        case TokenType.CONST:
        case TokenType.VAR:
        case TokenType.LET:
        case TokenType.ENUM:
        case TokenType.INTERFACE:
        case TokenType.IMPORT:
        case TokenType.EXPORT:
        case TokenType.SUPER:
        case TokenType.STATIC:
        case TokenType.PACKAGE:
        case TokenType.PRIVATE:
        case TokenType.PROTECTED:
        case TokenType.PUBLIC:
        case TokenType.IMPLEMENTS:
        case TokenType.WITH:
        case TokenType.DEBUGGER:
        case TokenType.YIELD:
        case TokenType.AWAIT:
            return true;
        default:
            return false;
    }
}

fn bool ident_is(char[] name, char[] word) @inline => name == word;

fn bool Parser.ts_type_specifier(&self) {
    if (!self.lex.ts_mode || !self.at_word("type")) return false;
    if (try next = self.peek()) {
        return (next.type == TokenType.IDENTIFIER && !self.is_word(next, "as"))
            || (next.type == TokenType.STRING && !next.is_template);
    }
    return false;
}
