// Scope resolution over the flat AST (plan 101, stage 4).
//
// One traversal builds the scope tree, a binding per (scope, name), a site per declaration
// occurrence in source order, and the identifier references; a second pass resolves each
// reference up the scope chain and marks a binding captured when the reference sits in another
// function (or behind a `with`) than the binding. A direct `eval` makes every binding of its
// function and of the enclosing functions captured.
module boomkat::ast;

import boomkat::ast::vec;

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

const char SCOPE_ARROW = 0x01;
const char SCOPE_STRICT = 0x02;
const char SCOPE_HAS_EVAL = 0x04;      // a direct eval call sits in this function's own code
const char SCOPE_CAPTURE_ALL = 0x08;   // this function or one nested in it calls eval
const char SCOPE_USES_ARGUMENTS = 0x10;
const char SCOPE_FIELD_INIT = 0x20;    // a class field initialiser
const char SCOPE_STATIC_BLOCK = 0x40;
const char SCOPE_HAS_WITH = 0x80;      // a `with` statement sits in this function's own code

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
    char flags;
    uint parent;
    uint func;        // the nearest enclosing function-like scope, or this one
    uint node;
    uint open;        // byte offset of the node's main token
    uint fn_flags;    // FNF_* of a function scope
    uint site_start;  // sites recorded while this scope was open: [site_start, site_end)
    uint site_end;
}

struct Binding {
    uint name;
    uint scope;
    DeclKind kind;
    bool captured;
}

// One declaration occurrence. `scope` is where it appears; the binding may live in an enclosing
// scope (a var inside a block binds in the function).
struct Site {
    uint binding;
    uint node;
    uint scope;
    DeclKind kind;
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
    uint cur;
    uint atom_arguments;
    uint atom_eval;
    bool failed;
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
    self.sites.push({ .binding = b, .node = node, .scope = self.cur, .kind = kind });
    return b;
}

fn uint Resolver.var_scope(&self) @inline {
    return self.scopes.data[self.cur].func;
}

// ---- scopes ----

fn uint Resolver.push_scope(&self, ScopeKind kind, uint node, char flags = 0, uint fn_flags = 0) {
    uint id = (uint)self.scopes.len;
    uint func = id;
    bool func_like = kind == ScopeKind.GLOBAL || kind == ScopeKind.MODULE || kind == ScopeKind.FUNCTION;
    char inherited = 0;
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
    char flags = 0;
    if (is_arrow) flags |= SCOPE_ARROW;
    if ((fnf & FNF_STRICT) != 0) flags |= SCOPE_STRICT;
    uint mark = (uint)self.annexb.len;
    uint fs = self.push_scope(ScopeKind.FUNCTION, n, flags, fnf);
    uint params = self.ast.field(rec, FN_PARAMS);
    uint pc = self.ast.list_len(params);
    for (uint i = 0; i < pc; i++) self.bind_pattern(self.ast.list_item(params, i), DeclKind.PARAM);
    uint body = self.ast.field(rec, FN_BODY);
    if ((fnf & FNF_EXPR_BODY) != 0) {
        self.node(body);
    } else {
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
    if (is_decl && name != 0) self.declare(self.cur, name, DeclKind.CLASS);
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
                self.push_scope(ScopeKind.FUNCTION, m, SCOPE_STATIC_BLOCK | SCOPE_STRICT, FNF_STATIC_BLOCK);
                self.list(self.ast.lhs.data[m]);
                self.pop_scope();
            default:
        }
    }
    self.pop_scope();
}

fn void Resolver.var_decl(&self, uint n) {
    char kind = self.ast.flags.data[n] & 0x7F;
    DeclKind dk = kind == VAR_KIND_VAR ? DeclKind.VAR : (kind == VAR_KIND_LET ? DeclKind.LET : DeclKind.CONST);
    uint list = self.ast.lhs.data[n];
    uint count = self.ast.list_len(list);
    for (uint i = 0; i < count; i++) {
        uint d = self.ast.list_item(list, i);
        self.bind_pattern(self.ast.lhs.data[d], dk);
        self.node(self.ast.rhs.data[d]);
    }
}

fn bool Resolver.is_lexical_head(&self, uint n) {
    return n != 0 && self.ast.tags.data[n] == NodeTag.VAR_DECL
        && (self.ast.flags.data[n] & 0x7F) != VAR_KIND_VAR;
}

fn void Resolver.func_decl(&self, uint n) {
    uint name = self.ast.lhs.data[n];
    if (name != 0) {
        bool top = self.is_func_scope(self.cur);
        if (top) {
            bool is_mod = self.scopes.data[self.cur].kind == ScopeKind.MODULE;
            self.declare(self.cur, name, is_mod ? DeclKind.LET : DeclKind.FUNC);
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
    if (n == 0) return;
    NodeTag tag = self.ast.tags.data[n];
    switch (tag) {
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
            self.push_scope(ScopeKind.BLOCK, n);
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
            self.scopes.data[self.var_scope()].flags |= SCOPE_HAS_WITH;
            self.push_scope(ScopeKind.WITH, n);
            self.sub_stmt(self.ast.rhs.data[n]);
            self.pop_scope();
        case FOR:
            uint q = self.ast.lhs.data[n];
            uint init = self.ast.extra.data[q];
            bool scoped = self.is_lexical_head(init);
            if (scoped) self.push_scope(ScopeKind.FOR, n);
            self.node(init);
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
            if (lt == NodeTag.ARRAY_PAT || lt == NodeTag.OBJECT_PAT) {
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
                self.push_scope(ScopeKind.CATCH, handler);
                self.bind_pattern(param, DeclKind.CATCH);
                self.node(handler);
                self.pop_scope();
            }
            self.node(self.ast.extra.data[t + 2]);
        case SWITCH:
            self.node(self.ast.lhs.data[n]);
            self.push_scope(ScopeKind.SWITCH, n);
            uint cases = self.ast.rhs.data[n];
            uint count = self.ast.list_len(cases);
            for (uint i = 0; i < count; i++) {
                uint c = self.ast.list_item(cases, i);
                self.node(self.ast.lhs.data[c]);
                self.list(self.ast.rhs.data[c]);
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
            self.node(self.ast.lhs.data[n]);
        case EXPORT_DEFAULT:
            self.node(self.ast.lhs.data[n]);
        case EXPORT_NAMED:
            return;
        case EXPORT_ALL:
            return;
        case PROGRAM:
            bool is_mod = (self.ast.flags.data[n] & PROGRAM_MODULE) != 0;
            char flags = (self.ast.flags.data[n] & PROGRAM_STRICT) != 0 ? SCOPE_STRICT : 0;
            self.push_scope(is_mod ? ScopeKind.MODULE : ScopeKind.GLOBAL, n, flags);
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
                if (dynamic || sc.func != from_func) self.bindings.data[b].captured = true;
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
    self.resolve_refs();
}

// ---- queries ----

// The innermost scope of one of the kinds in `mask` (a bit per ScopeKind) opened by the node whose
// main token is at byte offset `open`, or 0.
fn uint Resolver.scope_at(&self, uint open, uint mask) {
    // Scopes are created in source order, so `open` is non-decreasing.
    sz lo = 1;
    sz hi = self.scopes.len;
    while (lo < hi) {
        sz mid = (lo + hi) / 2;
        if (self.scopes.data[mid].open < open) { lo = mid + 1; } else { hi = mid; }
    }
    uint found = 0;
    for (sz i = lo; i < self.scopes.len && self.scopes.data[i].open == open; i++) {
        if (((mask >> (uint)self.scopes.data[i].kind) & 1) != 0) found = (uint)i;
    }
    return found;
}

fn bool decl_is_lexical(DeclKind k) @inline {
    return k == DeclKind.LET || k == DeclKind.CONST || k == DeclKind.CLASS;
}
