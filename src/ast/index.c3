// The AST index (plan 101, stage 5): a flat AST and its resolved scopes, built over a compile's
// source and read by the compiler's declaration and capture scans in place of re-lexing. In
// compare mode (`--compare-ast`) the compiler still runs its own scans and each result is checked
// against the index; disagreements print as `AST-COMPARE` lines on stderr.
module boomkat::ast;

import boomkat::lexer;
import std::io;
import boomkat::ast::vec;

enum ScanKind : char {
    LEXICAL,         // let/const/class directly in a function body or script
    LEXICAL_FN,      // the same plus function declarations: a block or case block
    VAR,             // var names anywhere in the body outside nested functions
}

const uint COMPARE_MAX_NAMES = 64;   // the legacy scans stop collecting at this many names
const uint COMPARE_AST_NAMES = 4096;

struct AstIndex {
    Ast tree;
    Parser parser;
    Lexer lexer;
    Resolver res;
    Vec{uint} paren_slots;   // open-addressed: function scope by the offset of its parameter list's `(`
    AstIndex* prev;
    bool built;
    bool use;           // the scans read the index
    uint mismatches;
}

tlocal AstIndex* index_state;
bool index_enabled = true;   // build an index per compile and let the scans read it
bool compare_enabled;        // build an index per compile, check the legacy scans against it

// Parse and resolve `source`; the result is the active comparison until `index_end`.
fn AstIndex* index_begin(char[] source, void* heap, ParseOptions opts) {
    AstIndex* c = mem::new(AstIndex);
    c.prev = index_state;
    index_state = c;
    c.lexer = lexer::lexer_init(source, heap);
    c.tree.init(source);
    uint? root = parse_program(&c.parser, &c.tree, &c.lexer, opts);
    if (catch err = root) {
        if (compare_enabled) {
            SourcePos at = c.tree.position(c.parser.err_pos);
            io::eprintfn("AST-COMPARE PARSE-FAILED at %d:%d", at.line, at.col);
        }
        return c;
    }
    c.res.init(&c.tree);
    c.res.run(root);
    c.index_parens();
    c.built = true;
    c.use = index_enabled && !compare_enabled;
    // A program the early-error pass rejects is left to the legacy compiler's scans and error
    // reporting until the pass replaces them.
    Early early;
    early.init(&c.tree);
    defer early.free();
    if (!early.run(root) || !early.conflicts(&c.res)) {
        if (compare_enabled) {
            SourcePos at = c.tree.position(early.err_pos);
            io::eprintfn("AST-COMPARE EARLY-ERROR at %d:%d: %s", at.line, at.col, early.error_message());
        }
        c.use = false;
    }
    return c;
}

fn void index_end(AstIndex* c) {
    index_state = c.prev;
    if (c.built) {
        c.res.free();
        c.paren_slots.free();
    }
    c.parser.destroy();
    c.tree.free();
    c.lexer.free_arena();
    mem::free(c);
}

// A function scope's parameter list `(` offset, 0 for an arrow or a scope that is not a function.
fn uint AstIndex.paren_of(&self, uint scope) {
    Scope* sc = &self.res.scopes.data[scope];
    if (sc.kind != ScopeKind.FUNCTION) return 0;
    NodeTag t = self.tree.tags.data[sc.node];
    if (t != NodeTag.FUNC_DECL && t != NodeTag.FUNC_EXPR) return 0;
    return self.tree.field(self.tree.rhs.data[sc.node], FN_PAREN);
}

fn void AstIndex.index_parens(&self) {
    sz cap = 16;
    while (cap < self.res.scopes.len * 2) cap *= 2;
    self.paren_slots.init(cap);
    for (sz i = 0; i < cap; i++) self.paren_slots.push(0);
    uint mask = (uint)cap - 1;
    for (uint s = 1; s < (uint)self.res.scopes.len; s++) {
        uint paren = self.paren_of(s);
        if (paren == 0) continue;
        uint i = (paren * 0x9E3779B1) & mask;
        while (self.paren_slots.data[i] != 0) i = (i + 1) & mask;
        self.paren_slots.data[i] = s;
    }
}

// The function scope whose parameter list opens at byte offset `paren`, or 0.
fn uint AstIndex.function_at_paren(&self, uint paren) {
    if (self.paren_slots.len == 0) return 0;
    uint mask = (uint)self.paren_slots.len - 1;
    uint i = (paren * 0x9E3779B1) & mask;
    while (true) {
        uint s = self.paren_slots.data[i];
        if (s == 0) return 0;
        if (self.paren_of(s) == paren) return s;
        i = (i + 1) & mask;
    }
}

fn bool bytes_eq(char[] a, char[] b) {
    if (a.len != b.len) return false;
    for (sz i = 0; i < a.len; i++) if (a[i] != b[i]) return false;
    return true;
}

// The sites the resolver records for `scope` in the way `kind` collects them, in source order.
fn uint Resolver.query_sites(&self, uint scope, ScanKind kind, uint* out, uint cap) {
    Scope* sc = &self.scopes.data[scope];
    uint n = 0;
    for (uint i = sc.site_start; i < sc.site_end && n < cap; i++) {
        Site* s = &self.sites.data[i];
        bool take = false;
        switch (kind) {
            case LEXICAL:
                take = s.scope == scope && (s.kind == DeclKind.LET || s.kind == DeclKind.CONST || s.kind == DeclKind.CLASS);
            case LEXICAL_FN:
                take = s.scope == scope && (s.kind == DeclKind.LET || s.kind == DeclKind.CONST
                    || s.kind == DeclKind.CLASS || s.kind == DeclKind.FUNC_BLOCK);
            case VAR:
                take = s.kind == DeclKind.VAR && !s.head && self.scopes.data[s.scope].func == sc.func;
        }
        if (take) out[n++] = i;
    }
    return n;
}

const String[] CONTEXTUAL_WORDS = { "await", "yield", "let", "static", "async", "of", "get", "set" };

// Why the AST may record `site` where the legacy token scan does not: a declarator after one with
// an initializer (`let a = 1, b`), or a binding named by a contextual keyword token
// (`class await {}`). Null when the legacy scan has no excuse.
fn String AstIndex.legacy_omits(&self, Site* s, char[] name) {
    if (s.late) return "late-declarator";
    if (s.exported) return "exported-class";
    if (s.no_semi) return "asi-terminated-declaration";
    if (s.kind == DeclKind.CLASS) return "class-after-asi";
    foreach (w : CONTEXTUAL_WORDS) if (bytes_eq(name, (char[])w)) return "contextual-keyword";
    return "";
}

// A name the legacy scan collected that is a real declaration of another scope, or that lies past
// the end of the function it was scanning: the scan ran past the end of its body.
fn bool AstIndex.is_overrun(&self, uint scope, char[] nm) {
    usz off = (usz)nm.ptr - (usz)self.lexer.source.ptr;
    Scope* fs = &self.res.scopes.data[self.res.scopes.data[scope].func];
    if (fs.kind == ScopeKind.FUNCTION) {
        NodeTag t = self.tree.tags.data[fs.node];
        if (t == NodeTag.FUNC_DECL || t == NodeTag.FUNC_EXPR || t == NodeTag.ARROW) {
            uint end = self.tree.field(self.tree.rhs.data[fs.node], FN_SRC_END);
            if (off >= end) return true;
        }
    }
    for (uint i = 1; i < (uint)self.res.sites.len; i++) {
        if (self.tree.main_tok.data[self.res.sites.data[i].node] == (uint)off) return true;
    }
    return false;
}

// Step `at` back over whitespace and comments.
fn uint AstIndex.skip_trivia_back(&self, uint at) {
    char[] src = self.lexer.source;
    while (at > 0) {
        char c = src[at - 1];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            at--;
        } else if (c == '/' && at > 1 && src[at - 2] == '*') {
            at -= 2;
            while (at > 1 && !(src[at - 2] == '/' && src[at - 1] == '*')) at--;
            if (at < 2) return 0;
            at -= 2;
        } else {
            // A line comment ends at the newline just skipped.
            // Only a short line is searched: a comment ending a minified megabyte is not worth it.
            uint line = at;
            while (line > 0 && at - line < 2000 && src[line - 1] != '\n') line--;
            bool found = false;
            for (uint i = line; i + 1 < at; i++) {
                if (src[i] == '/' && src[i + 1] == '/') { at = i; found = true; break; }
            }
            if (!found) return at;
        }
    }
    return 0;
}

// A scan that runs after a body's directive prologue starts at the end of the last directive.
// Walk back over the directives to the offset just inside the body's `{`; a Script or Module body
// has none and starts at 0.
fn uint AstIndex.body_start(&self, uint origin) {
    char[] src = self.lexer.source;
    uint at = origin;
    while (at > 0) {
        at = self.skip_trivia_back(at);
        if (at == 0) return 0;
        char c = src[at - 1];
        if (c == '{') return at;
        if (c == ';') {
            at--;
        } else if (c == '"' || c == '\'') {
            at--;
            while (at > 0 && (src[at - 1] != c || (at > 1 && src[at - 2] == '\\'))) at--;
            if (at == 0) return origin;
            at--;
        } else {
            return origin;
        }
    }
    return 0;
}

// `let` directly before the name: the legacy scan read `let x` as a declaration where the source
// is the identifier `let` ended by ASI.
fn bool AstIndex.follows_let(&self, char[] nm) {
    uint off = (uint)((usz)nm.ptr - (usz)self.lexer.source.ptr);
    uint at = self.skip_trivia_back(off);
    char[] src = self.lexer.source;
    return at >= 3 && src[at - 3] == 'l' && src[at - 2] == 'e' && src[at - 1] == 't';
}

// The scope a declaration scan starting at `origin` reads, 0 when there is none.
fn uint AstIndex.names_scope(&self, uint origin) {
    return self.res.scope_at(self.body_start(origin));
}

// The function scope a capture scan starting at `origin` reads, 0 when there is none.
fn uint AstIndex.captures_scope(&self, uint origin, bool global_mode) {
    if (global_mode) return 1;
    uint at = self.skip_trivia_forward(origin);
    uint key = (at < (uint)self.lexer.source.len && self.lexer.source[at] == '{') ? at + 1 : at;
    return self.res.scope_at(key);
}

fn void AstIndex.names(&self, ScanKind kind, uint origin, char[][] legacy) {
    if (!self.built) return;
    uint scope = self.names_scope(origin);
    if (scope == 0) {
        io::eprintfn("AST-COMPARE %s @%d: no scope (legacy=%d names)", ScanKind::names[kind.ordinal], origin, legacy.len);
        self.mismatches++;
        return;
    }
    uint[COMPARE_AST_NAMES] got;
    uint n = self.res.query_sites(scope, kind, &got, COMPARE_AST_NAMES);
    // Walk both lists in order; each name only one side has needs a recorded reason.
    uint i = 0;
    uint j = 0;
    bool same = true;
    String why = "";
    while (same && (i < n || j < legacy.len)) {
        Site* s = i < n ? &self.res.sites.data[got[i]] : null;
        char[] nm = i < n ? self.tree.atoms.get(self.res.bindings.data[s.binding].name) : (char[]){};
        if (j == legacy.len && legacy.len >= COMPARE_MAX_NAMES) break;
        if (i < n && j < legacy.len && bytes_eq(nm, legacy[j])) {
            i++;
            j++;
        } else if (i < n && self.legacy_omits(s, nm).len > 0) {
            why = self.legacy_omits(s, nm);
            i++;
        } else if (j < legacy.len && self.is_overrun(scope, legacy[j])) {
            why = "scan-overrun";
            j++;
        } else if (j < legacy.len && self.follows_let(legacy[j])) {
            why = "let-identifier";
            j++;
        } else if (j == legacy.len && kind == ScanKind.VAR) {
            why = "scan-truncated";
            i = n;
        } else {
            same = false;
        }
    }
    if (same) {
        if (why.len > 0) io::eprintfn("AST-KNOWN %s %s", why, ScanKind::names[kind.ordinal]);
        return;
    }
    self.mismatches++;
    io::eprintf("AST-COMPARE %s @%d scope %d: legacy=[", ScanKind::names[kind.ordinal], origin, scope);
    foreach (k, nm : legacy) {
        usz off = (usz)nm.ptr - (usz)self.lexer.source.ptr;
        io::eprintf("%s%s@%d", k > 0 ? "," : "", (String)nm, (uint)off);
    }
    io::eprintf("] ast=[");
    for (uint k = 0; k < n; k++) {
        Site* s = &self.res.sites.data[got[k]];
        io::eprintf("%s%s", k > 0 ? "," : "", (String)self.tree.atoms.get(self.res.bindings.data[s.binding].name));
    }
    io::eprintf("]\n");
}

// Step `at` forward over whitespace and comments.
fn uint AstIndex.skip_trivia_forward(&self, uint at) {
    char[] src = self.lexer.source;
    uint len = (uint)src.len;
    while (at < len) {
        char c = src[at];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f') {
            at++;
        } else if (c == 0xC2 && at + 1 < len && src[at + 1] == 0xA0) {
            at += 2;  // U+00A0
        } else if (c == 0xE2 && at + 2 < len && src[at + 1] == 0x80 && (src[at + 2] == 0xA8 || src[at + 2] == 0xA9)) {
            at += 3;  // U+2028, U+2029
        } else if (c == '/' && at + 1 < len && src[at + 1] == '/') {
            while (at < len && src[at] != '\n' && src[at] != '\r') at++;
        } else if (c == '/' && at + 1 < len && src[at + 1] == '*') {
            at += 2;
            while (at + 1 < len && !(src[at] == '*' && src[at + 1] == '/')) at++;
            at += 2;
        } else {
            break;
        }
    }
    return at;
}

// Whether `b` is a captured binding the compiler's captured-name set steers. A Script or Module
// top-level binding lives in the global object or the module environment whatever closures reach
// it. A class's inner name and a function expression's own name are materialised by the class and
// function compilers, not through the set.
fn bool AstIndex.is_register_capture(&self, Binding* b) {
    if (!b.captured) return false;
    ScopeKind dk = self.res.scopes.data[b.scope].kind;
    if (dk == ScopeKind.GLOBAL || dk == ScopeKind.MODULE) return false;
    return b.kind != DeclKind.CLASS_INNER && b.kind != DeclKind.FN_NAME;
}

// The capture scan: every binding the resolver marks captured in the scanned function must be in
// the legacy name set (or the legacy scan gave up and captured everything).
fn void AstIndex.captures(&self, uint origin, bool global_mode, bool legacy_all, char[][] legacy) {
    if (!self.built) return;
    uint scope = self.captures_scope(origin, global_mode);
    if (scope == 0) {
        io::eprintfn("AST-COMPARE CAPTURES @%d: no scope", origin);
        self.mismatches++;
        return;
    }
    Scope* sc = &self.res.scopes.data[scope];
    if (legacy_all) return;
    // The legacy compiler resolves names behind a `with` dynamically, whatever this set says.
    if ((sc.flags & SCOPE_HAS_WITH) != 0) {
        io::eprintfn("AST-KNOWN with-resolved-dynamically CAPTURES");
        return;
    }
    if ((sc.flags & SCOPE_CAPTURE_ALL) != 0) {
        // The legacy scan reads only the body, so an eval in the parameter list is invisible to it.
        if ((sc.flags & SCOPE_EVAL_PARAMS) != 0) {
            io::eprintfn("AST-KNOWN eval-in-params CAPTURES");
            return;
        }
        io::eprintfn("AST-COMPARE CAPTURES @%d scope %d: AST captures everything, legacy does not", origin, scope);
        self.mismatches++;
        return;
    }
    for (uint i = self.res.func_start.data[scope]; i < self.res.func_start.data[scope + 1]; i++) {
        Binding* b = &self.res.bindings.data[self.res.func_items.data[i]];
        if (!self.is_register_capture(b)) continue;
        char[] nm = self.tree.atoms.get(b.name);
        bool found = false;
        foreach (l : legacy) if (bytes_eq(nm, l)) { found = true; break; }
        if (!found && bytes_eq(nm, (char[])"arguments")) {
            // The legacy scan reads the body only, so a parameter default's use is invisible to it.
            io::eprintfn("AST-KNOWN arguments-in-params CAPTURES");
        } else if (!found) {
            io::eprintfn("AST-COMPARE CAPTURES @%d scope %d: %s %s captured in AST, not in legacy", origin, scope,
                DeclKind::names[b.kind.ordinal], (String)nm);
            self.mismatches++;
        }
    }
}
