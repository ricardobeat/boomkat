// Early errors over the flat AST (plan 101, stage 6).
//
// The parser accepts what the grammar allows and the contextual rules it can decide while
// streaming tokens. This pass walks the finished tree top-down with the context those rules need
// (strictness after a "use strict" directive, generator and async code, class bodies, labels) and
// rejects the rest of ES2024's early errors. Redeclarations are checked against the resolver's sites by `Early.conflicts`.
module boomkat::ast;

import boomkat::ast::vec;
import boomkat::compiler;
import boomkat::lexer;

struct EarlyLabel {
    uint atom;
    bool loop;
}

struct PrivateName {
    uint atom;
    bool is_static;
    char accessor;   // 0 not an accessor, 1 getter, 2 setter, 3 getter and setter
}

// What `await`, `yield`, `arguments` and `return` mean at the node being walked.
struct EarlyCtx {
    bool strict;
    bool is_generator;
    bool await_reserved;    // `await` is not an identifier
    bool in_params;         // walking a formal parameter list
    bool ban_arguments;     // class field initialisers and static blocks, through arrows
    bool in_static_block;
}

enum IdRole : char {
    REF,       // IdentifierReference
    BIND,      // BindingIdentifier
    TARGET,    // an assignment target
}

struct Early {
    Ast* ast;
    EarlyCtx ctx;
    bool is_module;
    uint root;
    Vec{EarlyLabel} labels;
    uint label_base;
    uint breakable;      // enclosing loops and switches in the current function
    uint iterating;      // enclosing loops
    Vec{PrivateName} privates;
    Vec{uint} names;           // scratch: BoundNames of a parameter list or catch parameter
    bool failed;
    uint err_pos;
    char[160] err_msg;
    uint err_len;
    // Atoms for the words the rules test.
    uint a_eval;
    uint a_arguments;
    uint a_await;
    uint a_yield;
    uint a_let;
    uint a_constructor;
    uint a_prototype;
    uint a_proto;
    uint[9] strict_reserved;
    uint[40] keywords;
    uint keyword_count;
}

fn void Early.init(&self, Ast* ast) {
    self.ast = ast;
    self.labels.init(16);
    self.privates.init(16);
    self.names.init(16);
    self.a_eval = ast.atoms.intern("eval");
    self.a_arguments = ast.atoms.intern("arguments");
    self.a_await = ast.atoms.intern("await");
    self.a_yield = ast.atoms.intern("yield");
    self.a_let = ast.atoms.intern("let");
    self.a_constructor = ast.atoms.intern("constructor");
    self.a_prototype = ast.atoms.intern("prototype");
    self.a_proto = ast.atoms.intern("__proto__");
    String[9] sr = { "implements", "interface", "let", "package", "private", "protected", "public", "static", "yield" };
    for (usz i = 0; i < 9; i++) self.strict_reserved[i] = ast.atoms.intern((char[])sr[i]);
    String[] kw = {
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in",
        "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try",
        "typeof", "var", "void", "while", "with",
    };
    self.keyword_count = 0;
    foreach (w : kw) {
        self.keywords[self.keyword_count++] = ast.atoms.intern((char[])w);
    }
}

fn void Early.free(&self) {
    self.labels.free();
    self.privates.free();
    self.names.free();
}

fn void Early.fail_at(&self, uint pos, String msg) {
    if (self.failed) return;
    self.failed = true;
    self.err_pos = pos;
    usz n = msg.len < self.err_msg.len ? msg.len : self.err_msg.len;
    for (usz i = 0; i < n; i++) self.err_msg[i] = msg[i];
    self.err_len = (uint)n;
}

fn String Early.error_message(&self) {
    return (String)self.err_msg[:self.err_len];
}

fn bool Early.is_strict_reserved(&self, uint atom) {
    foreach (a : self.strict_reserved) {
        if (a == atom) return true;
    }
    return false;
}

fn bool Early.is_keyword(&self, uint atom) {
    for (uint i = 0; i < self.keyword_count; i++) {
        if (self.keywords[i] == atom) return true;
    }
    return false;
}

// ---- identifiers ----

fn void Early.check_ident(&self, uint n, IdRole role) {
    uint atom = self.ast.lhs.data[n];
    uint at = self.ast.main_tok.data[n];
    if (self.is_keyword(atom)) return self.fail_at(at, "reserved word cannot be used as an identifier");
    if (self.ctx.strict) {
        if (self.is_strict_reserved(atom)) return self.fail_at(at, "reserved word cannot be used as an identifier in strict mode");
        if (role != IdRole.REF && (atom == self.a_eval || atom == self.a_arguments)) {
            return self.fail_at(at, role == IdRole.BIND ? "reserved word cannot be used as a binding identifier"
                                                       : "Assignment to eval or arguments is not allowed in strict mode");
        }
    }
    if (atom == self.a_yield && self.ctx.is_generator) return self.fail_at(at, "'yield' is a reserved word");
    if (atom == self.a_await && (self.ctx.await_reserved || self.is_module)) return self.fail_at(at, "'await' is a reserved word");
    if (atom == self.a_arguments && role != IdRole.BIND && self.ctx.ban_arguments) {
        return self.fail_at(at, "'arguments' is not allowed in class field initializer or static block");
    }
}

// ---- entry point ----

// Check the Program `root`. Returns false and sets the error on the first early error.
fn bool Early.run(&self, uint root) {
    char f = self.ast.flags.data[root];
    self.root = root;
    self.is_module = (f & PROGRAM_MODULE) != 0;
    self.ctx = {};
    self.ctx.strict = (f & PROGRAM_STRICT) != 0;
    self.ctx.await_reserved = self.is_module;
    self.list(self.ast.lhs.data[root]);
    return !self.failed;
}

fn void Early.list(&self, uint list) {
    uint n = self.ast.list_len(list);
    for (uint i = 0; i < n && !self.failed; i++) self.node(self.ast.list_item(list, i));
}

// ---- statements in single-statement positions ----

// The body of an if, loop, with or label: a declaration is an error there, apart from Annex B's
// plain function declaration as the body of an `if` or a (sloppy) label.
fn void Early.sub_stmt(&self, uint n, bool if_body) {
    if (n == 0) return;
    NodeTag tag = self.ast.tags.data[n];
    uint at = self.ast.main_tok.data[n];
    switch (tag) {
        case CLASS_DECL:
            return self.fail_at(at, "declaration not allowed as a single-statement body");
        case VAR_DECL:
            if ((self.ast.flags.data[n] & VAR_KIND_MASK) != VAR_KIND_VAR) {
                return self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        case FUNC_DECL:
            uint fnf = self.ast.field(self.ast.rhs.data[n], FN_FLAGS);
            if (!if_body || self.ctx.strict || (fnf & (FNF_ASYNC | FNF_GENERATOR)) != 0) {
                return self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        case LABELED:
            // A labelled function is not a Statement in these positions.
            uint body = n;
            while (self.ast.tags.data[body] == NodeTag.LABELED) body = self.ast.rhs.data[body];
            if (self.ast.tags.data[body] == NodeTag.FUNC_DECL) {
                return self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        default:
    }
    self.node(n);
}

// ---- patterns ----

// A binding pattern. `declared` collects BoundNames when non-null.
fn void Early.binding(&self, uint n, Vec{uint}* declared) {
    if (n == 0 || self.failed) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            self.check_ident(n, IdRole.BIND);
            if (declared != null) declared.push(self.ast.lhs.data[n]);
        case ARRAY_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.binding(self.ast.list_item(list, i), declared);
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.binding(self.ast.list_item(list, i), declared);
        case PAT_PROP:
            char f = self.ast.flags.data[n];
            if ((f & PROP_SHORTHAND_PAT) != 0) {
                self.binding(self.ast.lhs.data[n], declared);
                self.node(self.ast.rhs.data[n]);
            } else {
                self.pattern_key(n);
                self.binding(self.ast.rhs.data[n], declared);
            }
        case ASSIGN_PAT:
            self.binding(self.ast.lhs.data[n], declared);
            self.node(self.ast.rhs.data[n]);
        case REST:
            self.binding(self.ast.lhs.data[n], declared);
        default:
            self.node(n);
    }
}

// The key of a destructuring property: a private name is not a property key there.
fn void Early.pattern_key(&self, uint prop) {
    uint key = self.ast.lhs.data[prop];
    if (self.ast.tags.data[key] == NodeTag.PRIVATE_NAME) {
        return self.fail_at(self.ast.main_tok.data[key], "private names are only allowed in class bodies");
    }
    self.node(key);
}

// An assignment target: an identifier, a member expression or a pattern of targets.
fn void Early.target(&self, uint n) {
    if (n == 0 || self.failed) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            self.check_ident(n, IdRole.TARGET);
        case ARRAY_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.target(self.ast.list_item(list, i));
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.target(self.ast.list_item(list, i));
        case PAT_PROP:
            char f = self.ast.flags.data[n];
            if ((f & PROP_SHORTHAND_PAT) != 0) {
                self.target(self.ast.lhs.data[n]);
                self.node(self.ast.rhs.data[n]);
            } else {
                self.pattern_key(n);
                self.target(self.ast.rhs.data[n]);
            }
        case ASSIGN_PAT:
            self.target(self.ast.lhs.data[n]);
            self.node(self.ast.rhs.data[n]);
        case REST:
            self.target(self.ast.lhs.data[n]);
        default:
            self.node(n);
    }
}

// ---- functions ----

// Whether the names collected from `from` on repeat.
fn bool Early.has_duplicate(&self, uint from) {
    for (sz i = (sz)from + 1; i < self.names.len; i++) {
        for (sz j = (sz)from; j < i; j++) {
            if (self.names.data[i] == self.names.data[j]) return true;
        }
    }
    return false;
}

fn bool Early.is_simple_list(&self, uint params) {
    uint n = self.ast.list_len(params);
    for (uint i = 0; i < n; i++) {
        if (self.ast.tags.data[self.ast.list_item(params, i)] != NodeTag.IDENT) return false;
    }
    return true;
}

fn void Early.function(&self, uint n, bool is_arrow) {
    uint rec = self.ast.rhs.data[n];
    uint fnf = self.ast.field(rec, FN_FLAGS);
    uint name = self.ast.lhs.data[n];
    uint at = self.ast.main_tok.data[n];
    EarlyCtx outer = self.ctx;
    uint saved_label_base = self.label_base;
    uint saved_labels = (uint)self.labels.len;
    uint saved_breakable = self.breakable;
    uint saved_iterating = self.iterating;
    defer {
        self.ctx = outer;
        self.label_base = saved_label_base;
        self.labels.truncate(saved_labels);
        self.breakable = saved_breakable;
        self.iterating = saved_iterating;
    }
    bool fstrict = (fnf & FNF_STRICT) != 0;
    bool is_async = (fnf & FNF_ASYNC) != 0;
    bool is_gen = (fnf & FNF_GENERATOR) != 0;

    // The name is bound in the enclosing code for a declaration, in the function itself for an
    // expression; either way a strict body makes it a strict binding.
    if (name != 0) {
        if (self.ast.tags.data[n] == NodeTag.FUNC_DECL) {
            self.ctx.strict = fstrict;
            self.check_ident(name, IdRole.BIND);
            self.ctx = outer;
        } else {
            self.ctx.strict = fstrict;
            self.ctx.is_generator = is_gen;
            self.ctx.await_reserved = is_async || self.is_module;
            self.check_ident(name, IdRole.BIND);
            self.ctx = outer;
        }
    }

    // Parameters are walked in the function's own strictness, and for an arrow in the enclosing
    // async and generator context (an arrow has no yield or await of its own).
    self.ctx.strict = fstrict;
    self.ctx.in_params = true;
    if (!is_arrow) {
        self.ctx.is_generator = is_gen;
        self.ctx.await_reserved = is_async || self.is_module;
        self.ctx.ban_arguments = false;
        self.ctx.in_static_block = false;
    }
    if (is_arrow && is_async) self.ctx.await_reserved = true;
    uint params = self.ast.field(rec, FN_PARAMS);
    uint pc = self.ast.list_len(params);
    bool simple = (fnf & FNF_SIMPLE_PARAMS) != 0;
    uint mark = (uint)self.names.len;
    defer self.names.truncate(mark);
    for (uint i = 0; i < pc && !self.failed; i++) self.binding(self.ast.list_item(params, i), &self.names);
    if (self.failed) return;
    // UniqueFormalParameters, and the strict, non-simple and arrow cases of FormalParameters.
    if ((fstrict || !simple || is_arrow || (fnf & FNF_METHOD) != 0) && self.has_duplicate(mark)) {
        return self.fail_at(at, "duplicate parameter names are not allowed here");
    }
    if ((fnf & FNF_USE_STRICT) != 0 && !simple) {
        return self.fail_at(at, "Illegal 'use strict' directive in function with non-simple parameter list");
    }
    if ((fnf & FNF_GETTER) != 0 && pc != 0) return self.fail_at(at, "a getter must have no parameters");
    if ((fnf & FNF_SETTER) != 0) {
        if (pc != 1 || self.ast.tags.data[self.ast.list_item(params, 0)] == NodeTag.REST) {
            return self.fail_at(at, "a setter must have exactly one non-rest parameter");
        }
    }
    self.ctx.in_params = false;
    if (is_arrow) {
        // The body of an arrow has no yield or await of its own either: `await` stays reserved
        // only when the arrow itself is async.
        self.ctx.is_generator = false;
        self.ctx.await_reserved = is_async || self.is_module;
    }
    self.label_base = (uint)self.labels.len;
    self.breakable = 0;
    self.iterating = 0;
    uint body = self.ast.field(rec, FN_BODY);
    if ((fnf & FNF_EXPR_BODY) != 0) {
        self.node(body);
    } else {
        self.list(self.ast.lhs.data[body]);
    }
}

// ---- classes ----

fn bool Early.is_private_declared(&self, uint atom) {
    for (sz i = 0; i < self.privates.len; i++) {
        if (self.privates.data[i].atom == atom) return true;
    }
    return false;
}

fn void Early.private_ref(&self, uint atom, uint at) {
    if (!self.is_private_declared(atom)) {
        self.fail_at(at, "private name is not declared in an enclosing class");
    }
}

fn bool Early.key_is(&self, uint key, bool computed, uint atom) {
    if (computed || self.ast.tags.data[key] != NodeTag.STRING) return false;
    return self.ast.lhs.data[key] == atom;
}

fn void Early.class_(&self, uint n) {
    uint rec = self.ast.rhs.data[n];
    uint name = self.ast.lhs.data[n];
    EarlyCtx outer = self.ctx;
    defer self.ctx = outer;
    // Everything in a class is strict code.
    self.ctx.strict = true;
    if (name != 0) self.check_ident(name, IdRole.BIND);
    uint heritage = self.ast.field(rec, CLS_HERITAGE);
    self.node(heritage);

    uint members = self.ast.field(rec, CLS_MEMBERS);
    uint count = self.ast.list_len(members);
    uint mark = (uint)self.privates.len;
    defer self.privates.truncate(mark);
    bool has_ctor = false;
    // Declare the private names first: a use may precede its declaration.
    for (uint i = 0; i < count && !self.failed; i++) {
        uint m = self.ast.list_item(members, i);
        NodeTag mt = self.ast.tags.data[m];
        if (mt != NodeTag.CLASS_METHOD && mt != NodeTag.CLASS_FIELD) continue;
        uint key = self.ast.lhs.data[m];
        if (self.ast.tags.data[key] != NodeTag.PRIVATE_NAME) continue;
        char f = self.ast.flags.data[m];
        uint atom = self.ast.lhs.data[key];
        uint at = self.ast.main_tok.data[key];
        if (atom == self.a_constructor) return self.fail_at(at, "#constructor is not allowed as a private name");
        char acc = 0;
        if (mt == NodeTag.CLASS_METHOD) {
            if ((f & MEMBER_GET) != 0) acc = 1;
            if ((f & MEMBER_SET) != 0) acc = 2;
        }
        bool is_static = (f & MEMBER_STATIC) != 0;
        bool found = false;
        for (sz j = (sz)mark; j < self.privates.len; j++) {
            PrivateName* p = &self.privates.data[j];
            if (p.atom != atom) continue;
            // A getter and a setter of the same name and staticness may share it.
            if (acc != 0 && p.accessor != 0 && p.accessor != acc && p.accessor != 3 && p.is_static == is_static) {
                p.accessor = 3;
                found = true;
                break;
            }
            return self.fail_at(at, "duplicate private name declaration");
        }
        if (!found) self.privates.push({ .atom = atom, .is_static = is_static, .accessor = acc });
    }
    for (uint i = 0; i < count && !self.failed; i++) {
        uint m = self.ast.list_item(members, i);
        char f = self.ast.flags.data[m];
        uint at = self.ast.main_tok.data[m];
        bool computed = (f & PROP_COMPUTED) != 0;
        bool is_static = (f & MEMBER_STATIC) != 0;
        switch (self.ast.tags.data[m]) {
            case CLASS_METHOD:
                uint key = self.ast.lhs.data[m];
                uint func = self.ast.rhs.data[m];
                uint fnf = self.ast.field(self.ast.rhs.data[func], FN_FLAGS);
                self.node(key);
                if ((fnf & FNF_CTOR) != 0) {
                    if (has_ctor) return self.fail_at(at, "a class may only have one constructor");
                    has_ctor = true;
                }
                if (self.key_is(key, computed, self.a_constructor) && !is_static
                    && (fnf & FNF_CTOR) == 0) {
                    return self.fail_at(at, "class constructor may not be an accessor, generator or async method");
                }
                if (is_static && self.key_is(key, computed, self.a_prototype)) {
                    return self.fail_at(at, "classes may not have a static property named 'prototype'");
                }
                self.node(func);
            case CLASS_FIELD:
                uint key = self.ast.lhs.data[m];
                self.node(key);
                if (self.key_is(key, computed, self.a_constructor)) {
                    return self.fail_at(at, "classes may not have a field named 'constructor'");
                }
                if (is_static && self.key_is(key, computed, self.a_prototype)) {
                    return self.fail_at(at, "classes may not have a static property named 'prototype'");
                }
                uint init = self.ast.rhs.data[m];
                if (init != 0) {
                    EarlyCtx saved = self.ctx;
                    self.ctx.is_generator = false;
                    self.ctx.in_params = false;
                    self.ctx.in_static_block = false;
                    self.ctx.await_reserved = self.is_module;
                    self.ctx.ban_arguments = true;
                    self.node(init);
                    self.ctx = saved;
                }
            case STATIC_BLOCK:
                self.static_block(m);
            default:
        }
    }
}

fn void Early.static_block(&self, uint m) {
    EarlyCtx saved = self.ctx;
    uint saved_label_base = self.label_base;
    uint saved_labels = (uint)self.labels.len;
    uint saved_breakable = self.breakable;
    uint saved_iterating = self.iterating;
    defer {
        self.ctx = saved;
        self.label_base = saved_label_base;
        self.labels.truncate(saved_labels);
        self.breakable = saved_breakable;
        self.iterating = saved_iterating;
    }
    self.ctx.is_generator = false;
    self.ctx.in_params = false;
    self.ctx.in_static_block = true;
    self.ctx.await_reserved = true;
    self.ctx.ban_arguments = true;
    self.label_base = (uint)self.labels.len;
    self.breakable = 0;
    self.iterating = 0;
    self.list(self.ast.lhs.data[m]);
}

// ---- the walk ----

fn bool Early.is_legacy_number(&self, uint n) {
    uint at = self.ast.main_tok.data[n];
    char[] src = self.ast.source;
    return (usz)at + 1 < src.len && src[at] == '0' && src[at + 1] >= '0' && src[at + 1] <= '9';
}

fn void Early.node(&self, uint n) {
    if (n == 0 || self.failed) return;
    if (stack_exhausted()) return self.fail_at(self.ast.main_tok.data[n], "code nested too deeply");
    NodeTag tag = self.ast.tags.data[n];
    uint at = self.ast.main_tok.data[n];
    switch (tag) {
        case NUMBER:
            if (self.ctx.strict && self.is_legacy_number(n)) {
                return self.fail_at(at, "a legacy octal or non-octal decimal literal is not allowed");
            }
        case STRING:
            if (self.ctx.strict && (self.ast.flags.data[n] & STR_OCTAL) != 0) {
                return self.fail_at(at, "octal escape sequences are not allowed in strict mode");
            }
        case DIRECTIVE:
            self.node(self.ast.lhs.data[n]);
        case REGEX:
            String err = compiler::regexp_literal_error(self.ast.atoms.get(self.ast.lhs.data[n]));
            if (err.len > 0) return self.fail_at(at, err);
        case IDENT:
            self.check_ident(n, IdRole.REF);
        case FUNC_EXPR:
            self.function(n, false);
        case ARROW:
            self.function(n, true);
        case FUNC_DECL:
            self.function(n, false);
        case CLASS_EXPR:
        case CLASS_DECL:
            self.class_(n);
        case UNARY:
            self.unary(n);
        case UPDATE_PRE:
        case UPDATE_POST:
            self.target(self.ast.lhs.data[n]);
        case ASSIGN:
            TokenType aop = (TokenType)(self.ast.flags.data[n] & 0x7F);
            if (self.ast.tags.data[self.ast.lhs.data[n]] == NodeTag.CALL
                && (aop == TokenType.LOG_AND_ASSIGN || aop == TokenType.LOG_OR_ASSIGN || aop == TokenType.NULLISH_ASSIGN)) {
                return self.fail_at(at, "invalid assignment target");
            }
            self.target(self.ast.lhs.data[n]);
            self.node(self.ast.rhs.data[n]);
        case LOGICAL:
        case BINARY:
            self.binary_chain(n);
        case AWAIT:
            if (self.ctx.in_params) return self.fail_at(at, "await expression is not allowed in formal parameters");
            self.node(self.ast.lhs.data[n]);
        case YIELD:
        case YIELD_STAR:
            if (self.ctx.in_params) return self.fail_at(at, "yield expression is not allowed in formal parameters");
            self.node(self.ast.lhs.data[n]);
        case PRIVATE_MEMBER:
            self.node(self.ast.lhs.data[n]);
            self.private_ref(self.ast.rhs.data[n], at);
        case PRIVATE_IN:
            self.private_ref(self.ast.lhs.data[n], at);
            self.node(self.ast.rhs.data[n]);
        case OBJECT:
            self.object(n);
        case VAR_DECL:
            self.var_decl(n, false);
        case IF:
            uint pair = self.ast.rhs.data[n];
            self.node(self.ast.lhs.data[n]);
            self.sub_stmt(self.ast.extra.data[pair], true);
            self.sub_stmt(self.ast.extra.data[pair + 1], true);
        case WHILE:
            self.node(self.ast.lhs.data[n]);
            self.loop_body(self.ast.rhs.data[n]);
        case DO_WHILE:
            self.loop_body(self.ast.lhs.data[n]);
            self.node(self.ast.rhs.data[n]);
        case FOR:
            uint q = self.ast.lhs.data[n];
            uint init = self.ast.extra.data[q];
            if (init != 0 && self.ast.tags.data[init] == NodeTag.VAR_DECL) {
                self.var_decl(init, false);
            } else {
                self.node(init);
            }
            self.node(self.ast.extra.data[q + 1]);
            self.node(self.ast.extra.data[q + 2]);
            self.loop_body(self.ast.extra.data[q + 3]);
        case FOR_IN:
        case FOR_OF:
            self.for_in_of(n);
        case WITH:
            if (self.ctx.strict) return self.fail_at(at, "'with' statement is not allowed in strict mode");
            self.node(self.ast.lhs.data[n]);
            self.sub_stmt(self.ast.rhs.data[n], false);
        case LABELED:
            self.labeled(n);
        case BREAK:
        case CONTINUE:
            self.jump(n);
        case SWITCH:
            self.switch_(n);
        case TRY:
            self.try_(n);
        case BLOCK:
            self.list(self.ast.lhs.data[n]);
        case IMPORT_DECL:
            uint specs = self.ast.rhs.data[n];
            uint count = self.ast.list_len(specs);
            for (uint i = 0; i < count && !self.failed; i++) {
                self.binding(self.ast.rhs.data[self.ast.list_item(specs, i)], null);
            }
        case EXPORT_NAMED:
        case EXPORT_ALL:
            return;
        case EXPORT_DECL:
        case EXPORT_DEFAULT:
            self.node(self.ast.lhs.data[n]);
        case PROGRAM:
            self.list(self.ast.lhs.data[n]);
        default:
            self.generic(n);
    }
}

// Children of a node with no early-error rule of its own, by the layout in `slots_of`.
fn void Early.generic(&self, uint n) {
    Slot[2] sl = slots_of(self.ast.tags.data[n]);
    self.generic_slot(sl[0], self.ast.lhs.data[n]);
    self.generic_slot(sl[1], self.ast.rhs.data[n]);
}

fn void Early.generic_slot(&self, Slot k, uint v) {
    switch (k) {
        case NODE:
            self.node(v);
        case LIST:
            self.list(v);
        case PAIR:
            self.node(self.ast.extra.data[v]);
            self.node(self.ast.extra.data[v + 1]);
        case TRIPLE:
            self.node(self.ast.extra.data[v]);
            self.node(self.ast.extra.data[v + 1]);
            self.node(self.ast.extra.data[v + 2]);
        case QUAD:
            self.node(self.ast.extra.data[v]);
            self.node(self.ast.extra.data[v + 1]);
            self.node(self.ast.extra.data[v + 2]);
            self.node(self.ast.extra.data[v + 3]);
        case TEMPLATE:
            uint exprs = self.ast.template_exprs(v);
            for (uint i = 0; i < exprs; i++) self.node(self.ast.template_expr(v, i));
        default:
    }
}

fn void Early.unary(&self, uint n) {
    uint operand = self.ast.lhs.data[n];
    if ((TokenType)(self.ast.flags.data[n] & 0x7F) == TokenType.DELETE) {
        uint target = operand;
        // `delete a?.#x` ends in a private member through the chain wrapper.
        if (self.ast.tags.data[target] == NodeTag.OPT_CHAIN) target = self.ast.lhs.data[target];
        NodeTag tt = self.ast.tags.data[target];
        if (tt == NodeTag.PRIVATE_MEMBER) {
            return self.fail_at(self.ast.main_tok.data[n], "Private fields can not be deleted");
        }
        if (self.ctx.strict && self.ast.tags.data[operand] == NodeTag.IDENT) {
            return self.fail_at(self.ast.main_tok.data[n], "delete of an unqualified identifier in strict mode");
        }
    }
    self.node(operand);
}

// `??` may not mix with `&&` or `||` unless one side is parenthesised.
fn void Early.check_nullish_mix(&self, uint n) {
    TokenType op = (TokenType)(self.ast.flags.data[n] & 0x7F);
    uint[2] sides = { self.ast.lhs.data[n], self.ast.rhs.data[n] };
    foreach (s : sides) {
        if (self.ast.tags.data[s] != NodeTag.LOGICAL || (self.ast.flags.data[s] & FLAG_PAREN) != 0) continue;
        TokenType sop = (TokenType)(self.ast.flags.data[s] & 0x7F);
        if ((op == TokenType.NULLISH) != (sop == TokenType.NULLISH)) {
            return self.fail_at(self.ast.main_tok.data[n], "'??' cannot be mixed with '&&' or '||' without parentheses");
        }
    }
}

// A left-nested run of binary and logical operators is walked iteratively from its innermost
// operand: `a + b + c + ...` can be arbitrarily long.
fn void Early.binary_chain(&self, uint n) {
    uint mark = (uint)self.names.len;
    uint cur = n;
    while (true) {
        NodeTag t = self.ast.tags.data[cur];
        if (t != NodeTag.BINARY && t != NodeTag.LOGICAL) break;
        self.names.push(cur);
        cur = self.ast.lhs.data[cur];
    }
    self.node(cur);
    while (self.names.len > mark && !self.failed) {
        uint op_node = self.names.data[self.names.len - 1];
        self.names.truncate(self.names.len - 1);
        if (self.ast.tags.data[op_node] == NodeTag.LOGICAL) self.check_nullish_mix(op_node);
        if (!self.failed) self.node(self.ast.rhs.data[op_node]);
    }
    self.names.truncate(mark);
}

fn void Early.object(&self, uint n) {
    uint list = self.ast.lhs.data[n];
    uint count = self.ast.list_len(list);
    bool seen_proto = false;
    for (uint i = 0; i < count && !self.failed; i++) {
        uint p = self.ast.list_item(list, i);
        char f = self.ast.flags.data[p];
        NodeTag pt = self.ast.tags.data[p];
        if (pt == NodeTag.PROP_INIT || pt == NodeTag.PROP_GET || pt == NodeTag.PROP_SET || pt == NodeTag.PROP_METHOD) {
            uint pkey = self.ast.lhs.data[p];
            if (self.ast.tags.data[pkey] == NodeTag.PRIVATE_NAME) {
                return self.fail_at(self.ast.main_tok.data[pkey], "private names are only allowed in class bodies");
            }
            if ((f & PROP_COMPUTED) == 0) self.node(pkey);
        }
        switch (pt) {
            case PROP_INIT:
                uint key = self.ast.lhs.data[p];
                if ((f & PROP_COMPUTED) != 0) {
                    self.node(key);
                } else if (self.key_is(key, false, self.a_proto)) {
                    if (seen_proto) return self.fail_at(self.ast.main_tok.data[p], "duplicate __proto__ fields are not allowed in object literals");
                    seen_proto = true;
                }
                self.node(self.ast.rhs.data[p]);
            case PROP_SHORTHAND:
                self.check_ident(self.ast.lhs.data[p], IdRole.REF);
                self.node(self.ast.rhs.data[p]);
            case PROP_GET:
            case PROP_SET:
            case PROP_METHOD:
                if ((f & PROP_COMPUTED) != 0) self.node(self.ast.lhs.data[p]);
                self.node(self.ast.rhs.data[p]);
            default:
                self.node(p);
        }
    }
}

// ---- statements ----

fn void Early.loop_body(&self, uint body) {
    self.breakable++;
    self.iterating++;
    self.sub_stmt(body, false);
    self.iterating--;
    self.breakable--;
}

fn void Early.var_decl(&self, uint n, bool head) {
    char kind = self.ast.flags.data[n] & VAR_KIND_MASK;
    uint list = self.ast.lhs.data[n];
    uint count = self.ast.list_len(list);
    for (uint i = 0; i < count && !self.failed; i++) {
        uint d = self.ast.list_item(list, i);
        uint target = self.ast.lhs.data[d];
        uint init = self.ast.rhs.data[d];
        if (kind != VAR_KIND_VAR) self.no_let(target);
        self.binding(target, null);
        if (init == 0 && !head) {
            if (kind == VAR_KIND_CONST) return self.fail_at(self.ast.main_tok.data[d], "const declaration requires an initializer");
            if (self.ast.tags.data[target] != NodeTag.IDENT) return self.fail_at(self.ast.main_tok.data[d], "destructuring declaration requires an initializer");
        }
        self.node(init);
    }
}

// A lexical declaration may not bind the name `let`.
fn void Early.no_let(&self, uint n) {
    if (n == 0 || self.failed) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            if (self.ast.lhs.data[n] == self.a_let) self.fail_at(self.ast.main_tok.data[n], "'let' cannot be a lexically bound name");
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.no_let(self.ast.list_item(list, i));
        case PAT_PROP:
            if ((self.ast.flags.data[n] & PROP_SHORTHAND_PAT) != 0) {
                self.no_let(self.ast.lhs.data[n]);
            } else {
                self.no_let(self.ast.rhs.data[n]);
            }
        case ASSIGN_PAT:
        case REST:
            self.no_let(self.ast.lhs.data[n]);
        default:
    }
}

fn void Early.for_in_of(&self, uint n) {
    uint left = self.ast.lhs.data[n];
    uint pair = self.ast.rhs.data[n];
    bool is_of = self.ast.tags.data[n] == NodeTag.FOR_OF;
    if (self.ast.tags.data[left] == NodeTag.VAR_DECL) {
        char kind = self.ast.flags.data[left] & VAR_KIND_MASK;
        uint d = self.ast.list_item(self.ast.lhs.data[left], 0);
        uint target = self.ast.lhs.data[d];
        uint init = self.ast.rhs.data[d];
        if (init != 0) {
            // Annex B.3.5: `for (var x = 1 in y)` in sloppy code, a simple binding only.
            bool allowed = !is_of && kind == VAR_KIND_VAR && !self.ctx.strict
                && self.ast.tags.data[target] == NodeTag.IDENT;
            if (!allowed) return self.fail_at(self.ast.main_tok.data[d], "for-in/of loop variable declaration may not have an initializer");
        }
        self.var_decl(left, true);
    } else {
        self.target(left);
    }
    self.node(self.ast.extra.data[pair]);
    self.loop_body(self.ast.extra.data[pair + 1]);
}

fn void Early.labeled(&self, uint n) {
    uint atom = self.ast.lhs.data[n];
    uint at = self.ast.main_tok.data[n];
    for (sz i = self.label_base; i < self.labels.len; i++) {
        if (self.labels.data[i].atom == atom) return self.fail_at(at, "label has already been declared");
    }
    if (self.is_keyword(atom)) return self.fail_at(at, "reserved word cannot be used as a label");
    if (atom == self.a_yield && (self.ctx.is_generator || self.ctx.strict)) return self.fail_at(at, "reserved word cannot be used as a label");
    if (atom == self.a_await && (self.ctx.await_reserved || self.is_module)) return self.fail_at(at, "reserved word cannot be used as a label");
    if (self.ctx.strict && (self.is_strict_reserved(atom))) return self.fail_at(at, "reserved word cannot be used as a label");
    // A label is a loop label when the statement it names, through further labels, is a loop.
    uint body = self.ast.rhs.data[n];
    while (self.ast.tags.data[body] == NodeTag.LABELED) body = self.ast.rhs.data[body];
    NodeTag bt = self.ast.tags.data[body];
    bool loop = bt == NodeTag.FOR || bt == NodeTag.FOR_IN || bt == NodeTag.FOR_OF || bt == NodeTag.WHILE || bt == NodeTag.DO_WHILE;
    self.labels.push({ .atom = atom, .loop = loop });
    uint inner = self.ast.rhs.data[n];
    if (self.ast.tags.data[inner] == NodeTag.FUNC_DECL) {
        uint fnf = self.ast.field(self.ast.rhs.data[inner], FN_FLAGS);
        if (self.ctx.strict || (fnf & (FNF_ASYNC | FNF_GENERATOR)) != 0) {
            self.fail_at(self.ast.main_tok.data[inner], "declaration not allowed as a single-statement body");
        } else {
            self.node(inner);
        }
    } else if (self.ast.tags.data[inner] == NodeTag.LABELED) {
        self.labeled(inner);
    } else {
        self.sub_stmt(inner, false);
    }
    self.labels.truncate(self.labels.len - 1);
}

fn void Early.jump(&self, uint n) {
    uint label = self.ast.lhs.data[n];
    uint at = self.ast.main_tok.data[n];
    bool is_break = self.ast.tags.data[n] == NodeTag.BREAK;
    if (label == 0) {
        if (is_break && self.breakable == 0) return self.fail_at(at, "'break' is only valid inside a loop or switch");
        if (!is_break && self.iterating == 0) return self.fail_at(at, "'continue' is only valid inside a loop");
        return;
    }
    for (sz i = self.labels.len; i > self.label_base; i--) {
        EarlyLabel l = self.labels.data[i - 1];
        if (l.atom != label) continue;
        if (!is_break && !l.loop) return self.fail_at(at, "'continue' may only target a loop label");
        return;
    }
    self.fail_at(at, "undefined label");
}

fn void Early.switch_(&self, uint n) {
    self.node(self.ast.lhs.data[n]);
    uint cases_rec = self.ast.rhs.data[n];
    uint cases = self.ast.extra.data[cases_rec];
    uint count = self.ast.list_len(cases);
    bool seen_default = false;
    self.breakable++;
    for (uint i = 0; i < count && !self.failed; i++) {
        uint c = self.ast.list_item(cases, i);
        uint test = self.ast.lhs.data[c];
        if (test == 0) {
            if (seen_default) return self.fail_at(self.ast.main_tok.data[c], "More than one default clause in switch statement");
            seen_default = true;
        }
        self.node(test);
        self.list(self.ast.rhs.data[c]);
    }
    self.breakable--;
}

fn void Early.try_(&self, uint n) {
    uint t = self.ast.rhs.data[n];
    self.node(self.ast.lhs.data[n]);
    uint param = self.ast.extra.data[t];
    uint handler = self.ast.extra.data[t + 1];
    if (param != 0) {
        uint mark = (uint)self.names.len;
        defer self.names.truncate(mark);
        self.binding(param, &self.names);
        if (!self.failed && self.has_duplicate(mark)) {
            return self.fail_at(self.ast.main_tok.data[param], "duplicate catch parameter name");
        }
    }
    self.node(handler);
    self.node(self.ast.extra.data[t + 2]);
}

// ---- module exports ----

// A module export name that is a string literal must be well-formed Unicode: no lone surrogate.
// The lexer stores a lone surrogate as its three-byte generalised UTF-8 form.
fn bool Early.has_lone_surrogate(&self, uint atom) {
    char[] text = self.ast.atoms.get(atom);
    for (usz i = 0; i + 1 < text.len; i++) {
        if (text[i] == 0xED && text[i + 1] >= 0xA0) return true;
    }
    return false;
}

fn void Early.add_export(&self, uint name, uint at) {
    for (sz i = 0; i < self.names.len; i++) {
        if (self.names.data[i] == name) return self.fail_at(at, "duplicate export name");
    }
    self.names.push(name);
}

fn void Early.add_exported_bindings(&self, uint n, uint at) {
    if (n == 0 || self.failed) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            self.add_export(self.ast.lhs.data[n], at);
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.add_exported_bindings(self.ast.list_item(list, i), at);
        case PAT_PROP:
            if ((self.ast.flags.data[n] & PROP_SHORTHAND_PAT) != 0) {
                self.add_exported_bindings(self.ast.lhs.data[n], at);
            } else {
                self.add_exported_bindings(self.ast.rhs.data[n], at);
            }
        case ASSIGN_PAT:
        case REST:
            self.add_exported_bindings(self.ast.lhs.data[n], at);
        default:
    }
}

// The export names of a module must be unique, a local export must name a module-level binding,
// and string export and import names must be well-formed.
fn void Early.module_exports(&self, Resolver* r) {
    uint module_scope = 1;
    uint mark = (uint)self.names.len;
    defer self.names.truncate(mark);
    uint a_default = self.ast.atoms.intern("default");
    uint list = self.ast.lhs.data[self.root];
    uint count = self.ast.list_len(list);
    for (uint i = 0; i < count && !self.failed; i++) {
        uint n = self.ast.list_item(list, i);
        uint at = self.ast.main_tok.data[n];
        switch (self.ast.tags.data[n]) {
            case IMPORT_DECL:
                uint specs = self.ast.rhs.data[n];
                uint sc = self.ast.list_len(specs);
                for (uint j = 0; j < sc; j++) {
                    uint spec = self.ast.list_item(specs, j);
                    if (self.has_lone_surrogate(self.ast.lhs.data[spec])) return self.fail_at(at, "import name is not well-formed Unicode");
                }
            case EXPORT_DECL:
                uint d = self.ast.lhs.data[n];
                NodeTag dt = self.ast.tags.data[d];
                if (dt == NodeTag.VAR_DECL) {
                    uint dl = self.ast.lhs.data[d];
                    uint dc = self.ast.list_len(dl);
                    for (uint j = 0; j < dc; j++) self.add_exported_bindings(self.ast.lhs.data[self.ast.list_item(dl, j)], at);
                } else if (self.ast.lhs.data[d] != 0) {
                    self.add_export(self.ast.lhs.data[self.ast.lhs.data[d]], at);
                }
            case EXPORT_DEFAULT:
                self.add_export(a_default, at);
            case EXPORT_ALL:
                uint name = self.ast.rhs.data[n];
                if (name != 0) {
                    if (self.has_lone_surrogate(name)) return self.fail_at(at, "export name is not well-formed Unicode");
                    self.add_export(name, at);
                }
            case EXPORT_NAMED:
                uint specs = self.ast.lhs.data[n];
                bool reexport = self.ast.rhs.data[n] != 0;
                uint sc = self.ast.list_len(specs);
                for (uint j = 0; j < sc && !self.failed; j++) {
                    uint spec = self.ast.list_item(specs, j);
                    uint local = self.ast.lhs.data[spec];
                    uint exported = self.ast.rhs.data[spec];
                    uint sat = self.ast.main_tok.data[spec];
                    if (self.has_lone_surrogate(local) || self.has_lone_surrogate(exported)) {
                        return self.fail_at(sat, "export name is not well-formed Unicode");
                    }
                    if (!reexport && r.lookup(module_scope, local) == 0) {
                        return self.fail_at(sat, "export of an undeclared binding");
                    }
                    self.add_export(exported, sat);
                }
            default:
        }
    }
}

// ---- declaration conflicts ----

const char BF_LEX = 1;              // a lexical declaration binds the name in this scope
const char BF_PARAM = 2;
const char BF_CATCH = 4;
const char BF_CATCH_PATTERN = 8;    // a catch parameter that is a destructuring pattern
const char BF_PLAIN_FUNC = 16;      // every lexical declaration so far is a sloppy plain function

// A function declaration is lexical in a block, and in a module's top level; elsewhere it is
// var-like.
fn bool Early.site_is_lexical(&self, Resolver* r, Site* s) {
    switch (s.kind) {
        case LET:
        case CONST:
        case CLASS:
        case FUNC_BLOCK:
        case IMPORT:
            return true;
        case FUNC:
            return r.scopes.data[s.scope].kind == ScopeKind.MODULE;
        default:
            return false;
    }
}

fn bool Early.site_is_var_like(&self, Resolver* r, Site* s) {
    return s.kind == DeclKind.VAR || (s.kind == DeclKind.FUNC && r.scopes.data[s.scope].kind != ScopeKind.MODULE);
}

fn bool Early.is_plain_sloppy_function(&self, Resolver* r, Site* s) {
    if (s.kind != DeclKind.FUNC_BLOCK || s.decl == 0) return false;
    if ((r.scopes.data[s.scope].flags & SCOPE_STRICT) != 0) return false;
    uint fnf = self.ast.field(self.ast.rhs.data[s.decl], FN_FLAGS);
    return (fnf & (FNF_ASYNC | FNF_GENERATOR)) == 0;
}

// Redeclarations ES2024 rejects: duplicate lexical names, a lexical name that is also var-declared
// in its scope or a parameter, and the catch-parameter rules of Annex B.3.4.
fn bool Early.conflicts(&self, Resolver* r) {
    sz nb = (sz)r.bindings.len + 1;
    char[] flags = mem::new_array(char, nb)[:nb];
    defer mem::free(flags.ptr);
    // Pass 1: lexical duplicates, parameters and catch parameters.
    for (sz i = 1; i < (sz)r.sites.len && !self.failed; i++) {
        Site* s = &r.sites.data[i];
        uint at = self.ast.main_tok.data[s.node];
        if (s.kind == DeclKind.PARAM) {
            flags[s.binding] |= BF_PARAM;
        } else if (s.kind == DeclKind.CATCH) {
            flags[s.binding] |= BF_CATCH;
            if (s.pattern) flags[s.binding] |= BF_CATCH_PATTERN;
        } else if (self.site_is_lexical(r, s)) {
            char f = flags[s.binding];
            bool plain = self.is_plain_sloppy_function(r, s);
            if ((f & BF_LEX) != 0) {
                // Annex B.3.3.4: sloppy plain function declarations may repeat in a block.
                if (!(plain && (f & BF_PLAIN_FUNC) != 0)) { self.fail_at(at, "redeclaration of a lexical name"); return false; }
            } else {
                f |= BF_LEX;
                if (plain) f |= BF_PLAIN_FUNC;
                flags[s.binding] = f;
            }
            if ((f & BF_PARAM) != 0 && r.scopes.data[s.scope].kind == ScopeKind.FUNCTION) {
                { self.fail_at(at, "redeclaration of a parameter name"); return false; }
            }
            Scope* sc = &r.scopes.data[s.scope];
            if (sc.kind == ScopeKind.BLOCK && sc.parent != 0 && r.scopes.data[sc.parent].kind == ScopeKind.CATCH) {
                uint cb = r.lookup(sc.parent, self.ast.lhs.data[s.node]);
                if (cb != 0 && (flags[cb] & BF_CATCH) != 0) { self.fail_at(at, "redeclaration of a catch parameter"); return false; }
            }
        }
    }
    // A parameter declared after a lexical binding of the same function scope (parameters come
    // first in source order, so only the var-like pass below needs the full picture).
    // Pass 2: var-like declarations against the lexical names of the scopes between them and
    // their function.
    for (sz i = 1; i < (sz)r.sites.len && !self.failed; i++) {
        Site* s = &r.sites.data[i];
        if (!self.site_is_var_like(r, s)) continue;
        uint name = self.ast.lhs.data[s.node];
        uint at = self.ast.main_tok.data[s.node];
        uint x = s.scope;
        while (x != 0) {
            uint b = r.lookup(x, name);
            if (b != 0) {
                char f = flags[b];
                if ((f & BF_LEX) != 0) { self.fail_at(at, "redeclaration of a lexical name"); return false; }
                if ((f & BF_CATCH) != 0 && s.kind == DeclKind.VAR && (f & BF_CATCH_PATTERN) != 0) {
                    { self.fail_at(at, "redeclaration of a catch parameter"); return false; }
                }
            }
            if (r.scopes.data[x].func == x) break;
            x = r.scopes.data[x].parent;
        }
    }
    if (self.is_module && !self.failed) self.module_exports(r);
    return !self.failed;
}
