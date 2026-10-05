// Scope resolution over the flat AST (plan 101, stage 4).
//
// One traversal builds the scope tree, a binding per (scope, name), a site per declaration
// occurrence in source order, and the identifier references; a second pass resolves each
// reference up the scope chain and marks a binding captured when the reference sits in another
// function (or behind a `with`) than the binding. A direct `eval` makes every binding of its
// function and of the enclosing functions captured.
module boomkat::ast;

import boomkat::ast::vec;
import std::collections::list;

enum ScopeKind : char {
    NONE,
    GLOBAL,     // Script top level
    MODULE,     // Module top level
    FUNCTION,   // function, method, arrow, class field initialiser, static block
    BLOCK,
    CATCH,
    FOR,        // a for statement's let/const head
    SWITCH,
    CLASS,      // the class's inner name binding, heritage and computed keys
    WITH,       // the body of a `with` statement: names may resolve dynamically
}

const uint NO_INNER = 0xFFFFFFFF;

const ushort SCOPE_ARROW = 0x01;
const ushort SCOPE_STRICT = 0x02;
const ushort SCOPE_HAS_EVAL = 0x04;      // a direct eval call sits in this function's own code
const ushort SCOPE_CAPTURE_ALL = 0x08;   // this function or one nested in it calls eval
const ushort SCOPE_USES_ARGUMENTS = 0x10;
const ushort SCOPE_FIELD_INIT = 0x20;    // a class field initialiser
const ushort SCOPE_STATIC_BLOCK = 0x40;
const ushort SCOPE_HAS_WITH = 0x80;       // a `with` statement sits in this function or one nested in it
const ushort SCOPE_EVAL_PARAMS = 0x100;  // a direct eval call sits in this function's parameter list
const ushort SCOPE_CATCH_PATTERN = 0x200;

enum DeclKind : char {
    VAR,
    LET,
    CONST,
    CLASS,        // a class declaration's binding in its enclosing scope
    FUNC,         // a function declaration at a function, script or module top level
    FUNC_BLOCK,   // a function declaration inside a block (lexical there)
    PARAM,
    CATCH,
    IMPORT,
    FN_NAME,      // a function expression's own name
    CLASS_INNER,  // a class's immutable inner name binding
    ARGUMENTS,    // the implicit `arguments` object of a non-arrow function
    ANNEXB_VAR,   // the var binding Annex B.3.3 adds for a block-level function
}

struct Scope {
    ScopeKind kind;
    ushort flags;
    uint parent;
    uint func;        // the nearest enclosing function-like scope, or this one
    uint node;
    uint open;        // byte offset of the node's main token
    uint fn_flags;    // FNF_* of a function scope
    uint inner;       // byte offset just past the `{` of a block, function body or case block, else NO_INNER
    uint site_start;  // sites recorded while this scope was open: [site_start, site_end)
    uint site_end;
}

struct Binding {
    uint name;
    uint scope;
    DeclKind kind;
    bool captured;    // referenced from a nested function or through a `with`
    bool local_ref;   // referenced from the function that owns it
}

// One declaration occurrence. `scope` is where it appears; the binding may live in an enclosing
// scope (a var inside a block binds in the function).
struct Site {
    uint binding;
    uint node;        // the declared identifier
    uint decl;        // the FUNC_DECL of a function site, else 0
    uint scope;
    DeclKind kind;
    bool head;        // a `var` in a for-in/of or for head: not a VarDeclaredNames entry of the enclosing block
    bool late;        // a declarator after one with an initializer in the same declaration
    bool exported;    // a class or function declared by `export` or `export default`
    bool no_semi;     // a let/const/var declaration statement that ends by ASI
    bool pattern;     // declared inside a destructuring pattern
}

struct Ref {
    uint node;
    uint scope;
}

struct AnnexBCandidate {
    uint site;
    uint scope;       // the block scope holding the declaration
    uint name;
}

struct Resolver {
    Ast* ast;
    Vec{Scope} scopes;
    Vec{Binding} bindings;
    Vec{Site} sites;
    Vec{Ref} refs;
    Vec{uint} slots;           // open addressing: binding id, 0 = empty
    uint slot_count;
    Vec{AnnexBCandidate} annexb;
    Vec{uint} inner_slots;     // open addressing over Scope.inner: scope id, 0 = empty
    Vec{uint} func_start;      // bindings grouped by function scope: [func_start[f], func_start[f + 1]) of func_items
    Vec{uint} func_items;
    uint cur;
    bool head;
    bool in_params;
    bool late;
    bool exported;
    bool no_semi;
    bool pattern;
    uint decl;                 // the FUNC_DECL whose name is being declared
    uint export_child;
    uint atom_arguments;
    uint atom_eval;
    bool failed;
    uint err_pos;
}

fn void Resolver.init(&self, Ast* ast) {
    self.ast = ast;
    self.scopes.init(64);
    self.bindings.init(64);
    self.sites.init(64);
    self.refs.init(64);
    self.slots.init(128);
    self.annexb.init(16);
    for (sz i = 0; i < 128; i++) self.slots.push(0);
    self.slot_count = 0;
    // Index 0 of each vector is the null entry.
    self.scopes.push({});
    self.bindings.push({});
    self.sites.push({});
    self.atom_arguments = ast.atoms.intern("arguments");
    self.atom_eval = ast.atoms.intern("eval");
}

fn void Resolver.free(&self) {
    self.scopes.free();
    self.bindings.free();
    self.sites.free();
    self.refs.free();
    self.slots.free();
    self.annexb.free();
    self.inner_slots.free();
    self.func_start.free();
    self.func_items.free();
}

// ---- binding map ----

fn uint map_hash(uint scope, uint name) @inline {
    ulong k = ((ulong)scope << 32) | (ulong)name;
    k *= 0x9E3779B97F4A7C15;
    return (uint)(k >> 32);
}

fn uint Resolver.lookup(&self, uint scope, uint name) {
    uint mask = (uint)self.slots.len - 1;
    uint i = map_hash(scope, name) & mask;
    while (true) {
        uint b = self.slots.data[i];
        if (b == 0) return 0;
        Binding* bd = &self.bindings.data[b];
        if (bd.scope == scope && bd.name == name) return b;
        i = (i + 1) & mask;
    }
}

fn void Resolver.map_insert(&self, uint b) {
    uint mask = (uint)self.slots.len - 1;
    Binding* bd = &self.bindings.data[b];
    uint i = map_hash(bd.scope, bd.name) & mask;
    while (self.slots.data[i] != 0) i = (i + 1) & mask;
    self.slots.data[i] = b;
}

fn void Resolver.map_grow(&self) {
    sz ncap = self.slots.len * 2;
    self.slots.len = 0;
    for (sz i = 0; i < ncap; i++) self.slots.push(0);
    for (uint b = 1; b < (uint)self.bindings.len; b++) self.map_insert(b);
}

// Find or create the binding for `name` in `scope`.
fn uint Resolver.bind(&self, uint scope, uint name, DeclKind kind) {
    uint b = self.lookup(scope, name);
    if (b != 0) return b;
    if ((self.slot_count + 1) * 2 > (uint)self.slots.len) self.map_grow();
    b = (uint)self.bindings.len;
    self.bindings.push({ .name = name, .scope = scope, .kind = kind, .captured = false });
    self.map_insert(b);
    self.slot_count++;
    return b;
}

// Record a declaration occurrence of `name` (the IDENT node `node`), binding it in `scope`.
fn uint Resolver.declare(&self, uint scope, uint node, DeclKind kind) {
    uint name = self.ast.lhs.data[node];
    uint b = self.bind(scope, name, kind);
    self.sites.push({ .binding = b, .node = node, .decl = self.decl, .scope = self.cur, .kind = kind, .head = self.head && kind == DeclKind.VAR, .late = self.late, .exported = self.exported, .no_semi = self.no_semi, .pattern = self.pattern });
    return b;
}

fn uint Resolver.var_scope(&self) @inline {
    return self.scopes.data[self.cur].func;
}

// ---- scopes ----

fn uint Resolver.push_scope(&self, ScopeKind kind, uint node, ushort flags = 0, uint fn_flags = 0) {
    uint id = (uint)self.scopes.len;
    uint func = id;
    bool func_like = kind == ScopeKind.GLOBAL || kind == ScopeKind.MODULE || kind == ScopeKind.FUNCTION;
    ushort inherited = 0;
    if (self.cur != 0) {
        if (!func_like) func = self.scopes.data[self.cur].func;
        // Strictness is inherited.
        inherited = self.scopes.data[self.cur].flags & SCOPE_STRICT;
    }
    self.scopes.push({
        .kind = kind,
        .flags = flags | inherited,
        .parent = self.cur,
        .func = func,
        .node = node,
        .open = node != 0 ? self.ast.main_tok.data[node] : 0,
        .fn_flags = fn_flags,
        .inner = NO_INNER,
        .site_start = (uint)self.sites.len,
        .site_end = 0,
    });
    self.cur = id;
    return id;
}

fn void Resolver.pop_scope(&self) {
    Scope* s = &self.scopes.data[self.cur];
    s.site_end = (uint)self.sites.len;
    self.cur = s.parent;
}

fn bool Resolver.is_func_scope(&self, uint scope) @inline {
    return self.scopes.data[scope].func == scope;
}

// ---- references ----

fn void Resolver.ref(&self, uint node) {
    uint name = self.ast.lhs.data[node];
    self.refs.push({ .node = node, .scope = self.cur });
    if (name == self.atom_eval) {
        self.scopes.data[self.var_scope()].flags |= SCOPE_HAS_EVAL;
        if (self.in_params) self.scopes.data[self.var_scope()].flags |= SCOPE_EVAL_PARAMS;
    }
}

// ---- traversal ----

fn void Resolver.list(&self, uint list) {
    uint n = self.ast.list_len(list);
    for (uint i = 0; i < n; i++) self.node(self.ast.list_item(list, i));
}

// A statement in a position that takes a single Statement: an Annex B function declaration there
// is wrapped in an implicit block.
fn void Resolver.sub_stmt(&self, uint n) {
    if (n == 0) return;
    if (self.ast.tags.data[n] == NodeTag.FUNC_DECL) {
        self.push_scope(ScopeKind.BLOCK, n);
        self.node(n);
        self.pop_scope();
        return;
    }
    self.node(n);
}

fn void Resolver.bind_pattern(&self, uint n, DeclKind kind) {
    if (n == 0) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            uint target = (kind == DeclKind.VAR) ? self.var_scope() : self.cur;
            self.declare(target, n, kind);
        case ARRAY_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.bind_pattern(self.ast.list_item(list, i), kind);
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.bind_pattern(self.ast.list_item(list, i), kind);
        case PAT_PROP:
            char f = self.ast.flags.data[n];
            if ((f & PROP_SHORTHAND_PAT) != 0) {
                self.bind_pattern(self.ast.lhs.data[n], kind);
                self.node(self.ast.rhs.data[n]);
            } else {
                if ((f & PROP_COMPUTED) != 0) self.node(self.ast.lhs.data[n]);
                self.bind_pattern(self.ast.rhs.data[n], kind);
            }
        case ASSIGN_PAT:
            self.bind_pattern(self.ast.lhs.data[n], kind);
            self.node(self.ast.rhs.data[n]);
        case REST:
            self.bind_pattern(self.ast.lhs.data[n], kind);
        default:
            self.node(n);
    }
}

// An assignment pattern: its identifiers are references.
fn void Resolver.assign_pattern(&self, uint n) {
    if (n == 0) return;
    switch (self.ast.tags.data[n]) {
        case ARRAY_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.assign_pattern(self.ast.list_item(list, i));
        case OBJECT_PAT:
            uint list = self.ast.lhs.data[n];
            uint count = self.ast.list_len(list);
            for (uint i = 0; i < count; i++) self.assign_pattern(self.ast.list_item(list, i));
        case PAT_PROP:
            char f = self.ast.flags.data[n];
            if ((f & PROP_SHORTHAND_PAT) != 0) {
                self.ref(self.ast.lhs.data[n]);
                self.node(self.ast.rhs.data[n]);
            } else {
                if ((f & PROP_COMPUTED) != 0) self.node(self.ast.lhs.data[n]);
                self.assign_pattern(self.ast.rhs.data[n]);
            }
        case ASSIGN_PAT:
            self.assign_pattern(self.ast.lhs.data[n]);
            self.node(self.ast.rhs.data[n]);
        case REST:
            self.assign_pattern(self.ast.lhs.data[n]);
        default:
            self.node(n);
    }
}

fn void Resolver.function(&self, uint n, bool is_arrow) {
    uint rec = self.ast.rhs.data[n];
    uint fnf = self.ast.field(rec, FN_FLAGS);
    ushort flags = 0;
    if (is_arrow) flags |= SCOPE_ARROW;
    if ((fnf & FNF_STRICT) != 0) flags |= SCOPE_STRICT;
    uint mark = (uint)self.annexb.len;
    bool saved_head = self.head;
    bool saved_params = self.in_params;
    self.head = false;
    self.in_params = false;
    defer self.head = saved_head;
    defer self.in_params = saved_params;
    uint fs = self.push_scope(ScopeKind.FUNCTION, n, flags, fnf);
    uint params = self.ast.field(rec, FN_PARAMS);
    uint pc = self.ast.list_len(params);
    self.in_params = true;
    for (uint i = 0; i < pc; i++) self.bind_pattern(self.ast.list_item(params, i), DeclKind.PARAM);
    self.in_params = false;
    uint body = self.ast.field(rec, FN_BODY);
    if ((fnf & FNF_EXPR_BODY) != 0) {
        self.scopes.data[fs].inner = self.ast.field(rec, FN_BODY_START);
        self.node(body);
    } else {
        self.scopes.data[fs].inner = self.ast.main_tok.data[body] + 1;
        self.list(self.ast.lhs.data[body]);
    }
    // A function expression's own name is visible in its body unless the body declares it.
    uint name = self.ast.lhs.data[n];
    if (name != 0 && self.ast.tags.data[n] == NodeTag.FUNC_EXPR) {
        uint atom = self.ast.lhs.data[name];
        if (self.lookup(fs, atom) == 0) {
            uint b = self.bind(fs, atom, DeclKind.FN_NAME);
            self.sites.push({ .binding = b, .node = name, .scope = fs, .kind = DeclKind.FN_NAME });
        }
    }
    self.hoist_annexb(mark);
    self.pop_scope();
}

// Annex B.3.3: a block-level function declaration in sloppy code also binds a var of the same name
// in the function, unless that var would clash with a lexical binding between the block and the
// function or with a parameter.
fn void Resolver.hoist_annexb(&self, uint mark) {
    if ((self.scopes.data[self.cur].flags & SCOPE_STRICT) != 0) {
        self.annexb.truncate(mark);
        return;
    }
    uint fs = self.cur;
    for (uint i = mark; i < (uint)self.annexb.len; i++) {
        AnnexBCandidate c = self.annexb.data[i];
        bool ok = true;
        uint s = self.scopes.data[c.scope].parent;
        while (s != 0 && ok) {
            uint b = self.lookup(s, c.name);
            if (b != 0) {
                switch (self.bindings.data[b].kind) {
                    case LET:
                    case CONST:
                    case CLASS:
                    case FUNC_BLOCK:
                    case CLASS_INNER:
                        ok = false;
                    case PARAM:
                        if (s == fs) ok = false;
                    case CATCH:
                        if ((self.scopes.data[s].flags & SCOPE_CATCH_PATTERN) != 0) ok = false;
                    default:
                }
            }
            if (s == fs) break;
            s = self.scopes.data[s].parent;
        }
        if (ok) {
            uint b = self.bind(fs, c.name, DeclKind.ANNEXB_VAR);
            self.sites.push({ .binding = b, .node = self.sites.data[c.site].node, .scope = c.scope, .kind = DeclKind.ANNEXB_VAR });
        }
    }
    self.annexb.truncate(mark);
}

fn void Resolver.class_(&self, uint n, bool is_decl) {
    uint rec = self.ast.rhs.data[n];
    uint name = self.ast.lhs.data[n];
    if (is_decl && name != 0) {
        self.exported = n == self.export_child;
        self.declare(self.cur, name, DeclKind.CLASS);
        self.exported = false;
    }
    self.push_scope(ScopeKind.CLASS, n, SCOPE_STRICT);
    if (name != 0) self.declare(self.cur, name, DeclKind.CLASS_INNER);
    self.node(self.ast.field(rec, CLS_HERITAGE));
    uint members = self.ast.field(rec, CLS_MEMBERS);
    uint count = self.ast.list_len(members);
    for (uint i = 0; i < count; i++) {
        uint m = self.ast.list_item(members, i);
        char f = self.ast.flags.data[m];
        switch (self.ast.tags.data[m]) {
            case CLASS_METHOD:
                if ((f & PROP_COMPUTED) != 0) self.node(self.ast.lhs.data[m]);
                self.node(self.ast.rhs.data[m]);
            case CLASS_FIELD:
                if ((f & PROP_COMPUTED) != 0) self.node(self.ast.lhs.data[m]);
                uint init = self.ast.rhs.data[m];
                if (init != 0) {
                    self.push_scope(ScopeKind.FUNCTION, m, SCOPE_FIELD_INIT | SCOPE_STRICT, FNF_FIELD_INIT);
                    self.node(init);
                    self.pop_scope();
                }
            case STATIC_BLOCK:
                uint sb = self.push_scope(ScopeKind.FUNCTION, m, SCOPE_STATIC_BLOCK | SCOPE_STRICT, FNF_STATIC_BLOCK);
                self.scopes.data[sb].inner = self.ast.rhs.data[m] + 1;
                self.list(self.ast.lhs.data[m]);
                self.pop_scope();
            default:
        }
    }
    self.pop_scope();
}

fn void Resolver.var_decl(&self, uint n, bool head = false) {
    char kind = self.ast.flags.data[n] & VAR_KIND_MASK;
    DeclKind dk = kind == VAR_KIND_VAR ? DeclKind.VAR : (kind == VAR_KIND_LET ? DeclKind.LET : DeclKind.CONST);
    uint list = self.ast.lhs.data[n];
    uint count = self.ast.list_len(list);
    bool seen_init = false;
    bool no_semi = (self.ast.flags.data[n] & VAR_NO_SEMI) != 0;
    for (uint i = 0; i < count; i++) {
        uint d = self.ast.list_item(list, i);
        self.head = head;
        self.late = seen_init;
        self.no_semi = no_semi;
        self.bind_pattern(self.ast.lhs.data[d], dk);
        self.head = false;
        self.late = false;
        self.no_semi = false;
        if (self.ast.rhs.data[d] != 0) seen_init = true;
        self.node(self.ast.rhs.data[d]);
    }
}

fn bool Resolver.is_lexical_head(&self, uint n) {
    return n != 0 && self.ast.tags.data[n] == NodeTag.VAR_DECL
        && (self.ast.flags.data[n] & VAR_KIND_MASK) != VAR_KIND_VAR;
}

fn void Resolver.func_decl(&self, uint n) {
    uint name = self.ast.lhs.data[n];
    if (name != 0) {
        bool top = self.is_func_scope(self.cur);
        self.decl = n;
        self.exported = n == self.export_child;
        defer { self.decl = 0; self.exported = false; }
        if (top) {
            self.declare(self.cur, name, DeclKind.FUNC);
        } else {
            uint site = (uint)self.sites.len;
            self.declare(self.cur, name, DeclKind.FUNC_BLOCK);
            uint fnf = self.ast.field(self.ast.rhs.data[n], FN_FLAGS);
            if ((fnf & (FNF_ASYNC | FNF_GENERATOR)) == 0) {
                self.annexb.push({ .site = site, .scope = self.cur, .name = self.ast.lhs.data[name] });
            }
        }
    }
    self.function(n, false);
}

fn void Resolver.node(&self, uint n) {
    if (n == 0 || self.failed) return;
    if (stack_exhausted()) {
        self.failed = true;
        self.err_pos = self.ast.main_tok.data[n];
        return;
    }
    NodeTag tag = self.ast.tags.data[n];
    switch (tag) {
        case BINARY:
        case LOGICAL:
            self.binary_chain(n);
        case IDENT:
            self.ref(n);
        case FUNC_EXPR:
            self.function(n, false);
        case ARROW:
            self.function(n, true);
        case FUNC_DECL:
            self.func_decl(n);
        case CLASS_EXPR:
            self.class_(n, false);
        case CLASS_DECL:
            self.class_(n, true);
        case VAR_DECL:
            self.var_decl(n);
        case BLOCK:
            uint bs = self.push_scope(ScopeKind.BLOCK, n);
            self.scopes.data[bs].inner = self.ast.main_tok.data[n] + 1;
            self.list(self.ast.lhs.data[n]);
            self.pop_scope();
        case ASSIGN:
            uint target = self.ast.lhs.data[n];
            NodeTag tt = self.ast.tags.data[target];
            if (tt == NodeTag.ARRAY_PAT || tt == NodeTag.OBJECT_PAT) {
                self.assign_pattern(target);
            } else {
                self.node(target);
            }
            self.node(self.ast.rhs.data[n]);
        case IF:
            uint pair = self.ast.rhs.data[n];
            self.node(self.ast.lhs.data[n]);
            self.sub_stmt(self.ast.extra.data[pair]);
            self.sub_stmt(self.ast.extra.data[pair + 1]);
        case WHILE:
            self.node(self.ast.lhs.data[n]);
            self.sub_stmt(self.ast.rhs.data[n]);
        case DO_WHILE:
            self.sub_stmt(self.ast.lhs.data[n]);
            self.node(self.ast.rhs.data[n]);
        case LABELED:
            self.node(self.ast.rhs.data[n]);
        case WITH:
            self.node(self.ast.lhs.data[n]);
            // Every function around the statement contains a `with`.
            uint wf = self.var_scope();
            while (true) {
                self.scopes.data[wf].flags |= SCOPE_HAS_WITH;
                uint wp = self.scopes.data[wf].parent;
                if (wp == 0) break;
                wf = self.scopes.data[wp].func;
            }
            self.push_scope(ScopeKind.WITH, n);
            self.sub_stmt(self.ast.rhs.data[n]);
            self.pop_scope();
        case FOR:
            uint q = self.ast.lhs.data[n];
            uint init = self.ast.extra.data[q];
            bool scoped = self.is_lexical_head(init);
            if (scoped) self.push_scope(ScopeKind.FOR, n);
            if (init != 0 && self.ast.tags.data[init] == NodeTag.VAR_DECL) {
                self.var_decl(init, true);
            } else {
                self.node(init);
            }
            self.node(self.ast.extra.data[q + 1]);
            self.node(self.ast.extra.data[q + 2]);
            self.sub_stmt(self.ast.extra.data[q + 3]);
            if (scoped) self.pop_scope();
        case FOR_IN:
        case FOR_OF:
            uint left = self.ast.lhs.data[n];
            uint pair = self.ast.rhs.data[n];
            bool scoped = self.is_lexical_head(left);
            if (scoped) self.push_scope(ScopeKind.FOR, n);
            NodeTag lt = self.ast.tags.data[left];
            if (lt == NodeTag.VAR_DECL) {
                self.var_decl(left, true);
            } else if (lt == NodeTag.ARRAY_PAT || lt == NodeTag.OBJECT_PAT) {
                self.assign_pattern(left);
            } else {
                self.node(left);
            }
            self.node(self.ast.extra.data[pair]);
            self.sub_stmt(self.ast.extra.data[pair + 1]);
            if (scoped) self.pop_scope();
        case TRY:
            uint t = self.ast.rhs.data[n];
            self.node(self.ast.lhs.data[n]);
            uint param = self.ast.extra.data[t];
            uint handler = self.ast.extra.data[t + 1];
            if (handler != 0) {
                self.push_scope(ScopeKind.CATCH, handler,
                    param != 0 && self.ast.tags.data[param] != NodeTag.IDENT ? SCOPE_CATCH_PATTERN : 0);
                self.pattern = param != 0 && self.ast.tags.data[param] != NodeTag.IDENT;
                self.bind_pattern(param, DeclKind.CATCH);
                self.pattern = false;
                self.node(handler);
                self.pop_scope();
            }
            self.node(self.ast.extra.data[t + 2]);
        case SWITCH:
            self.node(self.ast.lhs.data[n]);
            uint cases_rec = self.ast.rhs.data[n];
            uint cases = self.ast.extra.data[cases_rec];
            uint sw = self.push_scope(ScopeKind.SWITCH, n);
            self.scopes.data[sw].inner = self.ast.extra.data[cases_rec + 1] + 1;
            uint count = self.ast.list_len(cases);
            for (uint i = 0; i < count; i++) {
                uint c = self.ast.list_item(cases, i);
                self.node(self.ast.lhs.data[c]);
                self.list(self.ast.field(self.ast.rhs.data[c], 0));
            }
            self.pop_scope();
        case IMPORT_DECL:
            uint specs = self.ast.rhs.data[n];
            uint count = self.ast.list_len(specs);
            for (uint i = 0; i < count; i++) {
                uint sp = self.ast.list_item(specs, i);
                self.declare(self.cur, self.ast.rhs.data[sp], DeclKind.IMPORT);
            }
        case EXPORT_DECL:
        case EXPORT_DEFAULT:
            self.export_child = self.ast.lhs.data[n];
            self.node(self.export_child);
        case EXPORT_NAMED:
            if (self.ast.rhs.data[n] == 0) {
                uint list = self.ast.lhs.data[n];
                for (uint i = 0; i < self.ast.list_len(list); i++) self.ref(self.ast.list_item(list, i));
            }
            return;
        case EXPORT_ALL:
            return;
        case PROGRAM:
            bool is_mod = (self.ast.flags.data[n] & PROGRAM_MODULE) != 0;
            ushort flags = (self.ast.flags.data[n] & PROGRAM_STRICT) != 0 ? SCOPE_STRICT : 0;
            uint ps = self.push_scope(is_mod ? ScopeKind.MODULE : ScopeKind.GLOBAL, n, flags);
            self.scopes.data[ps].inner = 0;
            uint mark = (uint)self.annexb.len;
            self.list(self.ast.lhs.data[n]);
            self.hoist_annexb(mark);
            self.pop_scope();
        default:
            self.generic(n);
    }
}

// Children of a node with no scoping or binding rule of its own, by the layout in `slots_of`.
fn void Resolver.generic(&self, uint n) {
    Slot[2] sl = slots_of(self.ast.tags.data[n]);
    self.generic_slot(sl[0], self.ast.lhs.data[n], n);
    self.generic_slot(sl[1], self.ast.rhs.data[n], n);
}

fn void Resolver.generic_slot(&self, Slot k, uint v, uint owner) {
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

// ---- resolution ----

fn void Resolver.resolve_refs(&self) {
    for (uint i = 0; i < (uint)self.refs.len; i++) {
        Ref r = self.refs.data[i];
        uint name = self.ast.lhs.data[r.node];
        uint from_func = self.scopes.data[r.scope].func;
        bool dynamic = false;
        uint s = r.scope;
        while (s != 0) {
            Scope* sc = &self.scopes.data[s];
            uint b = self.lookup(s, name);
            if (b == 0 && name == self.atom_arguments && sc.kind == ScopeKind.FUNCTION
                && (sc.flags & (SCOPE_ARROW | SCOPE_FIELD_INIT | SCOPE_STATIC_BLOCK)) == 0) {
                b = self.bind(s, name, DeclKind.ARGUMENTS);
                sc = &self.scopes.data[s];
                sc.flags |= SCOPE_USES_ARGUMENTS;
            }
            if (b != 0) {
                if (dynamic || sc.func != from_func) {
                    self.bindings.data[b].captured = true;
                } else {
                    self.bindings.data[b].local_ref = true;
                }
                break;
            }
            if (sc.kind == ScopeKind.WITH) dynamic = true;
            s = sc.parent;
        }
    }
    // A direct eval reads any binding of its function and of every function around it.
    for (uint s = 1; s < (uint)self.scopes.len; s++) {
        if ((self.scopes.data[s].flags & SCOPE_HAS_EVAL) == 0) continue;
        uint f = s;
        while (true) {
            self.scopes.data[f].flags |= SCOPE_CAPTURE_ALL;
            uint parent = self.scopes.data[f].parent;
            if (parent == 0) break;
            f = self.scopes.data[parent].func;
        }
    }
    for (uint b = 1; b < (uint)self.bindings.len; b++) {
        Binding* bd = &self.bindings.data[b];
        uint f = self.scopes.data[bd.scope].func;
        if ((self.scopes.data[f].flags & SCOPE_CAPTURE_ALL) != 0) bd.captured = true;
    }
}

// Build the scope tree for the Program `root` of `ast`.
fn void Resolver.run(&self, uint root) {
    self.cur = 0;
    self.node(root);
    if ((self.ast.flags.data[root] & PROGRAM_TS) != 0) self.erase_type_exports(root);
    self.resolve_refs();
    self.index_inner();
}

// ---- queries ----

fn void Resolver.index_inner(&self) {
    // Counting sort of the bindings by their function scope.
    uint nscopes = (uint)self.scopes.len;
    self.func_start.init((sz)nscopes + 2);
    for (uint i = 0; i < nscopes + 2; i++) self.func_start.push(0);
    for (uint b = 1; b < (uint)self.bindings.len; b++) {
        self.func_start.data[self.scopes.data[self.bindings.data[b].scope].func + 1]++;
    }
    for (uint i = 1; i < nscopes + 2; i++) self.func_start.data[i] += self.func_start.data[i - 1];
    self.func_items.init(self.bindings.len + 1);
    for (sz i = 0; i < self.bindings.len + 1; i++) self.func_items.push(0);
    Vec{uint} fill;
    fill.init((sz)nscopes + 2);
    for (uint i = 0; i < nscopes + 2; i++) fill.push(self.func_start.data[i]);
    for (uint b = 1; b < (uint)self.bindings.len; b++) {
        uint f = self.scopes.data[self.bindings.data[b].scope].func;
        self.func_items.data[fill.data[f]++] = b;
    }
    fill.free();

    sz cap = 16;
    while (cap < self.scopes.len * 2) cap *= 2;
    self.inner_slots.init(cap);
    for (sz i = 0; i < cap; i++) self.inner_slots.push(0);
    uint mask = (uint)cap - 1;
    for (uint s = 1; s < (uint)self.scopes.len; s++) {
        uint inner = self.scopes.data[s].inner;
        if (inner == NO_INNER) continue;
        uint i = (inner * 0x9E3779B1) & mask;
        while (self.inner_slots.data[i] != 0) i = (i + 1) & mask;
        self.inner_slots.data[i] = s;
    }
}

// The scope whose braces open just before byte offset `inner`, or 0.
fn uint Resolver.scope_at(&self, uint inner) {
    if (self.inner_slots.len == 0) return 0;
    uint mask = (uint)self.inner_slots.len - 1;
    uint i = (inner * 0x9E3779B1) & mask;
    while (true) {
        uint s = self.inner_slots.data[i];
        if (s == 0) return 0;
        if (self.scopes.data[s].inner == inner) return s;
        i = (i + 1) & mask;
    }
}

fn bool decl_is_lexical(DeclKind k) @inline {
    return k == DeclKind.LET || k == DeclKind.CONST || k == DeclKind.CLASS;
}

// A type-only declaration retains its atom on an empty statement. Runtime declarations win
// merges (a class and interface may share a name); unannotated exports of pure types disappear.
fn void Resolver.erase_type_exports(&self, uint root) {
    uint statements = self.ast.lhs.data[root];
    sz count = self.ast.atoms.entries.len;
    bool[] types = mem::new_array(bool, count)[:count];
    defer mem::free(types.ptr);
    for (uint i = 0; i < self.ast.list_len(statements); i++) {
        uint n = self.ast.list_item(statements, i);
        if (self.ast.tags.data[n] == NodeTag.EMPTY_STMT) types[self.ast.lhs.data[n]] = true;
    }
    for (uint i = 0; i < self.ast.list_len(statements); i++) {
        uint n = self.ast.list_item(statements, i);
        if (self.ast.tags.data[n] != NodeTag.EXPORT_NAMED || self.ast.rhs.data[n] != 0) continue;
        uint list = self.ast.lhs.data[n];
        uint keep = 0;
        for (uint j = 0; j < self.ast.list_len(list); j++) {
            uint spec = self.ast.list_item(list, j);
            uint name = self.ast.lhs.data[spec];
            if (types[name] && self.lookup(1, name) == 0) continue;
            self.ast.extra.data[list + 1 + keep++] = spec;
        }
        self.ast.extra.data[list] = keep;
    }
}

fn void Resolver.binary_chain(&self, uint n) {
    uint left = self.ast.lhs.data[n];
    NodeTag tag = self.ast.tags.data[left];
    if (tag != NodeTag.BINARY && tag != NodeTag.LOGICAL) {
        self.generic(n);
        return;
    }
    List{uint} right = { .allocator = mem };
    defer right.free();
    do {
        right.push(self.ast.rhs.data[n]);
        n = self.ast.lhs.data[n];
        tag = self.ast.tags.data[n];
    } while (tag == NodeTag.BINARY || tag == NodeTag.LOGICAL);
    self.node(n);
    for (sz i = right.len(); i > 0;) self.node(right[--i]);
}
