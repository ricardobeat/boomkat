// Deferred-body inline validation: the scope tree, declarations and references a
// discarded body leaves behind, checked while its grammar is parsed. The whole-
// unit resolver reads the refs and flags off the body's stub; the declarations
// and scopes exist only to run the redeclaration early errors at eval time, and
// are dropped when the body ends.
module boomkat::ast;

import boomkat::ast::vec;

// A (binding scope, name) deduplicated for the conflict flags.
struct DvBinding {
    uint scope;
    uint atom;
}

// ---- lifecycle ----

// Enter a function body that sits inside a discarded deferred subtree: a fresh
// scope tree and site list. The formal params are declared first so a body
// lexical may clash with them. Refs keep accumulating across nesting, so each
// body's own refs are the slice its walk appended.
fn void Parser.dv_body_enter(&self, uint params) {
    // Only the outermost body starts a fresh reference list. A nested body in
    // between suspends the enclosing scope tracking but not this accumulation.
    if (self.dv_marks.len == 0) { self.dv_refs.truncate(0); self.dv_flags = 0; }
    self.dv_marks.push((uint)self.dv_scopes.len);
    self.dv_marks.push((uint)self.dv_sites.len);
    self.dv_marks.push(self.dv_cur);
    self.dv_marks.push(self.dv_ref_base);
    self.dv_marks.push(self.dv_label_base);
    self.dv_marks.push(self.dv_breakable);
    self.dv_marks.push(self.dv_iterating);
    self.dv_ref_base = (uint)self.dv_refs.len;
    self.dv_label_base = (uint)self.dv_labels.len;
    self.dv_breakable = 0;
    self.dv_iterating = 0;
    self.dv_cur = (uint)self.dv_scopes.len;
    self.dv_scopes.push({ .kind = ScopeKind.FUNCTION, .parent = 0, .func = self.dv_cur });
    self.dv_track++;
    uint pc = self.ast.list_len(params);
    for (uint i = 0; i < pc; i++) {
        self.dv_declare_pattern(self.ast.list_item(params, i), DeclKind.PARAM);
    }
}

// Leave a function body: check its redeclaration errors, then drop its scopes and
// sites so the enclosing body's tracking resumes where it was. A label, loop or
// switch of the enclosing body also resumes: a nested body starts a new one.
fn bool Parser.dv_body_leave(&self) {
    uint n = (uint)self.dv_marks.len - 7;
    bool ok = !self.failed && self.dv_conflicts(self.dv_marks.data[n + 1]);
    // Restore even when a conflict or an earlier error failed the walk: the
    // parse aborts, but the unit's tracker state must not stay nested.
    self.dv_scopes.truncate((sz)self.dv_marks.data[n + 0]);
    self.dv_sites.truncate((sz)self.dv_marks.data[n + 1]);
    self.dv_cur = self.dv_marks.data[n + 2];
    self.dv_ref_base = self.dv_marks.data[n + 3];
    self.dv_labels.truncate((sz)self.dv_label_base);
    self.dv_label_base = self.dv_marks.data[n + 4];
    self.dv_breakable = self.dv_marks.data[n + 5];
    self.dv_iterating = self.dv_marks.data[n + 6];
    self.dv_marks.truncate((sz)n);
    self.dv_track--;
    return ok;
}

// Open a lexical scope inside a deferred body. No-op outside one.
fn void Parser.dv_push_scope(&self, ScopeKind kind) {
    if (!self.dv_on || self.dv_track == 0) return;
    uint id = (uint)self.dv_scopes.len;
    uint func = id;
    if (kind != ScopeKind.FUNCTION) func = self.dv_scopes.data[self.dv_cur].func;
    self.dv_scopes.push({ .kind = kind, .parent = self.dv_cur, .func = func });
    self.dv_cur = id;
}

fn void Parser.dv_pop_scope(&self) {
    if (!self.dv_on || self.dv_track == 0 || self.dv_cur == 0) return;
    self.dv_cur = self.dv_scopes.data[self.dv_cur].parent;
}

fn bool Parser.dv_is_func_scope(&self) @inline {
    return self.dv_cur != 0 && self.dv_scopes.data[self.dv_cur].kind == ScopeKind.FUNCTION;
}

// Record a declaration occurrence. `kind` uses the resolver's DeclKind; the site
// keeps the occurrence scope (`dv_cur`), and the binding scope is recomputed from
// the kind by the conflict pass (a `var` binds at the function scope).
fn void Parser.dv_declare(&self, uint atom, DeclKind kind, uint at, bool pattern = false, bool plain = false) {
    if (!self.dv_on || atom == 0) return;
    // Strict code may not bind `eval` or `arguments` (Early.check_ident). This
    // also covers class bodies, whose scope tracking is paused but whose nodes
    // are discarded with the enclosing deferred body.
    if (self.ctx.strict && (atom == self.dv_atom_eval || atom == self.dv_atom_arguments)) {
        self.fail_at(at, "reserved word cannot be used as a binding identifier");
        return;
    }
    if (self.dv_track == 0) return;
    self.dv_sites.push({ .atom = atom, .kind = kind, .scope = self.dv_cur, .at = at,
        .pattern = pattern, .plain = plain });
}

// Declare every binding identifier of a binding pattern (a catch parameter or a
// `var`/`let`/`const` declarator). Mirrors Resolver.bind_pattern.
fn void Parser.dv_declare_pattern(&self, uint n, DeclKind kind, bool is_pattern = false) {
    if (!self.dv_on || n == 0) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            self.dv_declare(self.ast.lhs.data[n], kind, self.ast.main_tok.data[n], is_pattern);
        case ARRAY_PAT:
            uint l = self.ast.lhs.data[n];
            uint c = self.ast.list_len(l);
            for (uint i = 0; i < c; i++) self.dv_declare_pattern(self.ast.list_item(l, i), kind, true);
        case OBJECT_PAT:
            uint l2 = self.ast.lhs.data[n];
            uint c2 = self.ast.list_len(l2);
            for (uint i = 0; i < c2; i++) self.dv_declare_pattern(self.ast.list_item(l2, i), kind, true);
        case PAT_PROP:
            if ((self.ast.flags.data[n] & PROP_SHORTHAND_PAT) != 0) {
                self.dv_declare_pattern(self.ast.lhs.data[n], kind, true);
            } else {
                self.dv_declare_pattern(self.ast.rhs.data[n], kind, true);
            }
        case ASSIGN_PAT:
            self.dv_declare_pattern(self.ast.lhs.data[n], kind, true);
        case REST:
            self.dv_declare_pattern(self.ast.lhs.data[n], kind, true);
        default:
            // A property key or a computed key expression is not a binding.
    }
}

// Record an identifier reference (over-approximated: every identifier, binding or
// reference, is recorded; a name that never escapes this body marks nothing). A
// reference to `eval` taints the body like the resolver's would.
fn void Parser.dv_ref(&self, uint atom) {
    if (!self.dv_on || atom == 0) return;
    self.dv_refs.push(atom);
    if (atom == self.dv_atom_eval) self.dv_flags |= BODY_HAS_EVAL;
}

fn void Parser.dv_with(&self) {
    if (self.dv_on) self.dv_flags |= BODY_HAS_WITH;
}

fn void Parser.dv_escape(&self) {
    if (self.dv_on) self.dv_flags |= BODY_HAS_ESCAPE;
}

// ---- redeclaration conflicts ----

fn uint dv_map_hash(uint scope, uint atom) @inline {
    ulong k = ((ulong)scope << 32) | (ulong)atom;
    k *= 0x9E3779B97F4A7C15;
    return (uint)(k >> 32);
}

fn void Parser.dv_map_insert(&self, uint b) {
    uint mask = (uint)self.dv_slot.len - 1;
    DvBinding* bd = &self.dv_binds.data[b];
    uint i = dv_map_hash(bd.scope, bd.atom) & mask;
    while (self.dv_slot.data[i] != 0) i = (i + 1) & mask;
    self.dv_slot.data[i] = b;
    self.dv_slot_count++;
}

fn void Parser.dv_map_grow(&self) {
    uint ncap = (uint)self.dv_slot.len * 2;
    self.dv_slot.zero(ncap);
    self.dv_slot_count = 0;
    for (uint b = 1; b < (uint)self.dv_binds.len; b++) self.dv_map_insert(b);
}

// Binding for `(bscope, atom)`: the index into `dv_binds`, creating one on a miss.
fn uint Parser.dv_bind(&self, uint bscope, uint atom) {
    uint b = self.dv_lookup(bscope, atom);
    if (b != 0xFFFFFFFF) return b;
    if ((self.dv_slot_count + 1) * 2 > (uint)self.dv_slot.len) self.dv_map_grow();
    b = (uint)self.dv_binds.len;
    self.dv_binds.push({ .scope = bscope, .atom = atom });
    self.dv_bflags.push(0);
    self.dv_map_insert(b);
    return b;
}

fn uint Parser.dv_lookup(&self, uint bscope, uint atom) {
    if (self.dv_binds.len == 1) return 0xFFFFFFFF;   // only the null binding present
    uint mask = (uint)self.dv_slot.len - 1;
    uint i = dv_map_hash(bscope, atom) & mask;
    while (true) {
        uint b = self.dv_slot.data[i];
        if (b == 0) return 0xFFFFFFFF;
        DvBinding* bd = &self.dv_binds.data[b];
        if (bd.scope == bscope && bd.atom == atom) return b;
        i = (i + 1) & mask;
    }
}

// A function declaration is lexical in a block; elsewhere (never a module in a
// deferred body) it is var-like.
fn bool dv_site_is_lexical(DeclKind k) @inline {
    return k == DeclKind.LET || k == DeclKind.CONST || k == DeclKind.CLASS
        || k == DeclKind.FUNC_BLOCK;
}

fn bool dv_site_is_var_like(DeclKind k) @inline {
    return k == DeclKind.VAR || k == DeclKind.FUNC;
}

// Redeclarations rejected by ECMA-262 early errors, ported from Early.conflicts
// for the sloppy, non-module bodies the deferral keeps. Two passes mirror the
// source: lexical duplicates and param/catch clashes, then var-like names against
// the lexical names of the scopes between them and their function.
fn bool Parser.dv_conflicts(&self, sz first) {
    sz nb = self.dv_sites.len;
    // Only lexical and catch declarations can conflict: var/function/param
    // duplicates are all legal in a sloppy body. Most bodies have none, so
    // skip the binding map entirely for them.
    bool risky = false;
    for (sz i = first; i < nb; i++) {
        DeclKind k = self.dv_sites.data[i].kind;
        if (k == DeclKind.LET || k == DeclKind.CONST || k == DeclKind.CLASS
            || k == DeclKind.FUNC_BLOCK || k == DeclKind.CATCH) { risky = true; break; }
    }
    if (!risky) {
        return !self.failed;
    }
    self.dv_binds.truncate(0);
    self.dv_binds.push({});   // null binding at index 0; slot 0 means "empty"
    self.dv_bflags.truncate(0);
    self.dv_bflags.push(0);
    self.dv_slot.zero((uint)self.dv_slot.len);
    self.dv_slot_count = 0;
    // Pass 1: lexical duplicates, parameters and catch parameters.
    for (sz i = first; i < nb && !self.failed; i++) {
        DvSite* s = &self.dv_sites.data[i];
        uint bscope = s.kind == DeclKind.VAR || s.kind == DeclKind.FUNC
            ? self.dv_scopes.data[s.scope].func : s.scope;
        uint b = self.dv_bind(bscope, s.atom);
        if (s.kind == DeclKind.PARAM) {
            self.dv_bflags.data[b] |= BF_PARAM;
        } else if (s.kind == DeclKind.CATCH) {
            self.dv_bflags.data[b] |= BF_CATCH;
            if (s.pattern) self.dv_bflags.data[b] |= BF_CATCH_PATTERN;
        } else if (dv_site_is_lexical(s.kind)) {
            char f = self.dv_bflags.data[b];
            bool plain = s.plain;
            if ((f & BF_LEX) != 0) {
                // Annex B.3.3.4: sloppy plain function declarations may repeat in a block.
                if (!(plain && (f & BF_PLAIN_FUNC) != 0)) {
                    self.fail_at(s.at, "redeclaration of a lexical name");
                    return false;
                }
            } else {
                f |= BF_LEX;
                if (plain) f |= BF_PLAIN_FUNC;
                self.dv_bflags.data[b] = f;
            }
            if ((f & BF_PARAM) != 0 && self.dv_scopes.data[s.scope].kind == ScopeKind.FUNCTION) {
                self.fail_at(s.at, "redeclaration of a parameter name");
                return false;
            }
            DvScope* sc = &self.dv_scopes.data[s.scope];
            if (sc.kind == ScopeKind.BLOCK && sc.parent != 0
                && self.dv_scopes.data[sc.parent].kind == ScopeKind.CATCH) {
                uint cb = self.dv_lookup(sc.parent, s.atom);
                if (cb != 0xFFFFFFFF && (self.dv_bflags.data[cb] & BF_CATCH) != 0) {
                    self.fail_at(s.at, "redeclaration of a catch parameter");
                    return false;
                }
            }
        }
    }
    // Pass 2: var-like declarations against the lexical names of the scopes
    // between them and their function.
    for (sz i = first; i < nb && !self.failed; i++) {
        DvSite* s = &self.dv_sites.data[i];
        if (!dv_site_is_var_like(s.kind)) continue;
        uint x = s.scope;
        while (x != 0) {
            uint b = self.dv_lookup(x, s.atom);
            if (b != 0xFFFFFFFF) {
                char f = self.dv_bflags.data[b];
                if ((f & BF_LEX) != 0) {
                    self.fail_at(s.at, "var and lexical declarations cannot share a name");
                    return false;
                }
                if ((f & BF_CATCH) != 0 && s.kind == DeclKind.VAR && (f & BF_CATCH_PATTERN) != 0) {
                    self.fail_at(s.at, "redeclaration of a catch parameter");
                    return false;
                }
            }
            if (self.dv_scopes.data[x].func == x) break;
            x = self.dv_scopes.data[x].parent;
        }
    }
    return !self.failed;
}

// ---- labels and jumps ----

// Enter or leave a loop body: `break` needs a loop or switch, `continue` a loop.
fn void Parser.dv_loop_enter(&self) {
    if (self.dv_on && self.dv_track != 0) { self.dv_breakable++; self.dv_iterating++; }
}
fn void Parser.dv_loop_leave(&self) {
    if (self.dv_on && self.dv_track != 0) { self.dv_breakable--; self.dv_iterating--; }
}
fn void Parser.dv_switch_enter(&self) {
    if (self.dv_on && self.dv_track != 0) self.dv_breakable++;
}
fn void Parser.dv_switch_leave(&self) {
    if (self.dv_on && self.dv_track != 0) self.dv_breakable--;
}

// A label is declared: duplicate labels are rejected, then it is pushed so the
// jumps it names can find it. Whether it names a loop through further labels is
// only known once the body is parsed, so `dv_label_finish` resolves it.
fn void Parser.dv_label_declare(&self, uint atom, uint at) {
    if (!self.dv_on || self.dv_track == 0) return;
    for (sz i = (sz)self.dv_label_base; i < self.dv_labels.len; i++) {
        if (self.dv_labels.data[i].atom == atom) { self.fail_at(at, "label has already been declared"); return; }
    }
    self.dv_labels.push({ .atom = atom, .loop = false, .continue_at = 0 });
}

// The labelled statement is done: walk its label chain the way Early.labeled
// does, then decide any `continue` that named this label and pop it.
fn void Parser.dv_label_finish(&self, uint body) {
    if (!self.dv_on || self.dv_track == 0 || self.dv_labels.len <= self.dv_label_base) return;
    uint b = body;
    while (b != 0 && self.ast.tags.data[b] == NodeTag.LABELED) b = self.ast.rhs.data[b];
    NodeTag t = self.ast.tags.data[b];
    bool loop = b != 0 && (t == NodeTag.FOR || t == NodeTag.FOR_IN || t == NodeTag.FOR_OF
        || t == NodeTag.WHILE || t == NodeTag.DO_WHILE);
    DvLabel* l = &self.dv_labels.data[self.dv_labels.len - 1];
    if (l.continue_at != 0 && !loop) {
        self.fail_at(l.continue_at, "continue may only target a loop label");
    }
    self.dv_labels.truncate((sz)(self.dv_labels.len - 1));
}

// A stub's refs are all resolved at the same scope, so repeated atoms are
// redundant there. Collapse them in place with a generation-stamped table;
// growing the table re-stamps the atoms already kept for this stub.
fn uint Parser.dv_unique_refs(&self, uint ref0, uint nrefs) {
    if (nrefs < 2) return nrefs;
    uint gen = ++self.dv_seen_gen;
    if (gen == 0) {
        self.dv_seen.zero((uint)self.dv_seen.len);
        gen = self.dv_seen_gen = 1;
    }
    uint out = 0;
    for (uint i = 0; i < nrefs; i++) {
        uint atom = self.dv_refs.data[ref0 + i];
        if (atom >= (uint)self.dv_seen.len) {
            uint ncap = (uint)self.dv_seen.len == 0 ? 16 : (uint)self.dv_seen.len;
            while (ncap <= atom) ncap *= 2;
            self.dv_seen.zero(ncap);
            for (uint j = 0; j < out; j++) self.dv_seen.data[self.dv_refs.data[ref0 + j]] = gen;
        }
        if (self.dv_seen.data[atom] == gen) continue;
        self.dv_seen.data[atom] = gen;
        self.dv_refs.data[ref0 + out] = atom;
        out++;
    }
    return out;
}

// A regular for head, unlike a for-in/of head, still requires `const` and
// destructuring declarators to have an initializer (Early.var_decl).
fn void Parser.dv_for_init_check(&self, uint init) {
    if (!self.dv_on || init == 0) return;
    if (self.ast.tags.data[init] != NodeTag.VAR_DECL) return;
    char kind = self.ast.flags.data[init] & VAR_KIND_MASK;
    if (kind != VAR_KIND_VAR && kind != VAR_KIND_LET && kind != VAR_KIND_CONST) return;
    uint list = self.ast.lhs.data[init];
    uint count = self.ast.list_len(list);
    for (uint i = 0; i < count; i++) {
        uint d = self.ast.list_item(list, i);
        if (self.ast.rhs.data[d] != 0) continue;
        uint target = self.ast.lhs.data[d];
        uint at = self.ast.main_tok.data[d];
        if (kind == VAR_KIND_CONST) {
            self.fail_at(at, "const declaration requires an initializer");
            return;
        }
        if (self.ast.tags.data[target] != NodeTag.IDENT) {
            self.fail_at(at, "destructuring declaration requires an initializer");
            return;
        }
    }
}

// A break or continue statement. Mirrors Early.jump.
fn void Parser.dv_jump(&self, uint label, uint at, bool is_break) {
    if (!self.dv_on || self.dv_track == 0) return;
    if (label == 0) {
        if (is_break && self.dv_breakable == 0) { self.fail_at(at, "break is only valid inside a loop or switch"); return; }
        if (!is_break && self.dv_iterating == 0) { self.fail_at(at, "continue is only valid inside a loop"); return; }
        return;
    }
    for (sz i = self.dv_labels.len; i > (sz)self.dv_label_base; i--) {
        DvLabel* l = &self.dv_labels.data[i - 1];
        if (l.atom != label) continue;
        if (!is_break && l.continue_at == 0) l.continue_at = at;
        return;
    }
    self.fail_at(at, "undefined label");
}

// A lexical binding may not be named `let` (Early.no_let).
fn void Parser.dv_no_let(&self, uint n) {
    if (!self.dv_on || n == 0 || self.failed) return;
    switch (self.ast.tags.data[n]) {
        case IDENT:
            if (self.ast.lhs.data[n] == self.dv_atom_let) {
                self.fail_at(self.ast.main_tok.data[n], "'let' cannot be a lexically bound name");
            }
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint l = self.ast.lhs.data[n];
            if (l == 0) return;
            uint c = self.ast.list_len(l);
            for (uint i = 0; i < c; i++) self.dv_no_let(self.ast.list_item(l, i));
        case PAT_PROP:
            if ((self.ast.flags.data[n] & PROP_SHORTHAND_PAT) != 0) {
                self.dv_no_let(self.ast.lhs.data[n]);
            } else {
                self.dv_no_let(self.ast.rhs.data[n]);
            }
        case ASSIGN_PAT:
        case REST:
            self.dv_no_let(self.ast.lhs.data[n]);
        default:
    }
}

// `eval`, `arguments` and the strict reserved words, which a class name (always
// strict code) may not use (Early.check_ident / is_strict_reserved).
fn bool Parser.dv_strict_word(&self, uint atom) {
    if (atom == self.dv_atom_eval || atom == self.dv_atom_arguments) return true;
    for (uint i = 0; i < 9; i++) {
        if (atom == self.dv_strict_words[i]) return true;
    }
    return false;
}

fn void Parser.dv_class_name(&self, uint name) {
    if (!self.dv_on || name == 0) return;
    if (self.dv_strict_word(self.ast.lhs.data[name])) {
        self.fail_at(self.ast.main_tok.data[name], "reserved word cannot be used as an identifier in strict mode");
    }
}

// Declarations in a single-statement body: only a sloppy plain function in an
// `if` body (or as a labelled function) is allowed by Annex B (Early.sub_stmt).
fn void Parser.dv_sub_stmt(&self, uint n, bool if_body) {
    if (!self.dv_on || n == 0 || self.failed) return;
    uint at = self.ast.main_tok.data[n];
    switch (self.ast.tags.data[n]) {
        case CLASS_DECL:
            self.fail_at(at, "declaration not allowed as a single-statement body");
        case VAR_DECL:
            if ((self.ast.flags.data[n] & VAR_KIND_MASK) != VAR_KIND_VAR) {
                self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        case FUNC_DECL:
            uint fnf = self.ast.field(self.ast.rhs.data[n], FN_FLAGS);
            if (!if_body || self.ctx.strict || (fnf & (FNF_ASYNC | FNF_GENERATOR)) != 0) {
                self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        case LABELED:
            uint body = n;
            while (body != 0 && self.ast.tags.data[body] == NodeTag.LABELED) body = self.ast.rhs.data[body];
            if (body != 0 && self.ast.tags.data[body] == NodeTag.FUNC_DECL) {
                self.fail_at(at, "declaration not allowed as a single-statement body");
            }
        default:
    }
}

// Duplicate BoundNames in a catch parameter (Early.try_ / has_duplicate).
fn void Parser.dv_catch_dup(&self, sz first) {
    for (sz i = first; i < self.dv_sites.len; i++) {
        for (sz j = i + 1; j < self.dv_sites.len; j++) {
            if (self.dv_sites.data[i].atom == self.dv_sites.data[j].atom) {
                self.fail_at(self.dv_sites.data[j].at, "duplicate catch parameter name");
                return;
            }
        }
    }
}

// A for-in/of head may not initialise its binding, except the sloppy Annex B
// `for (var x = init in obj)` with a plain identifier (Early.for_in_of).
fn void Parser.dv_for_in_of_head(&self, uint init, bool is_of) {
    if (!self.dv_on || init == 0) return;
    if (self.ast.tags.data[init] != NodeTag.VAR_DECL) return;
    uint list = self.ast.lhs.data[init];
    if (self.ast.list_len(list) == 0) return;
    uint d = self.ast.list_item(list, 0);
    if (self.ast.rhs.data[d] == 0) return;
    char kind = self.ast.flags.data[init] & VAR_KIND_MASK;
    uint target = self.ast.lhs.data[d];
    bool allowed = !is_of && kind == VAR_KIND_VAR && !self.ctx.strict
        && target != 0 && self.ast.tags.data[target] == NodeTag.IDENT;
    if (!allowed) {
        self.fail_at(self.ast.main_tok.data[d], "for-in/of loop variable declaration may not have an initializer");
    }
}
