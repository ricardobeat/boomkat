module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;
import boomkat::heap;
import std::collections::list;

// Generator fusion: `for (const x of g(args)) body` where `g` is a closed local
// generator compiles to g's body inlined in the loop's frame, with each
// `yield v;` binding x to v and running the loop body in place. No generator
// object, iterator result or resumption exists.
//
// The generator must be the only binding of its name in the unit, declared by
// a function or module scope enclosing the loop and only ever called, so the
// callee is known statically. Its body may refer only to its own parameters
// and let/const declarations; those names are renamed so the loop body, which
// is compiled between them, still sees the caller's bindings. It has no
// closures, `this`, `arguments`, try, nested for-in/of or labels, and `yield`
// appears only as a statement, so abandoning it on break or return is
// unobservable.

struct FuseState {
    // Generator code is being generated: names are renamed and yield/return
    // statements take the fused forms.
    bool renaming;
    // Distinguishes the renamed names of a fusion nested in another's loop body.
    char depth;
    List{char[]} names;
    ushort binding;
    uint name_idx;
    bool constant;
    uint body;
    // cur_lex_depth when the generator body started; leaving it pops the rest.
    int lex_base;
    List{uint} exits;
}

const uint FUSE_MAX_YIELDS = 3;
const uint FUSE_MAX_PARAMS = 8;

// A generator-local name, renamed out of the caller's namespace.
fn char[] CompilerContext.fuse_name(&self, char[] raw) {
    Heap* h = (Heap*)self.heap;
    foreach (n : self.fuse.names) {
        if (n != raw) continue;
        char[256] buf;
        if (raw.len + 2 > buf.len) break;
        buf[0] = '\x01';
        buf[1] = self.fuse.depth;
        buf[2 : raw.len] = raw[..];
        return h.str_intern(buf[:raw.len + 2]).get_data();
    }
    return h.str_intern(raw).get_data();
}

// The FUNC_DECL of the generator every call of `name` in this unit reaches,
// or 0 when that is not statically certain.
fn uint CompilerContext.fuse_find_generator(&self, char[] name) {
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    ast::Resolver* res = &idx.res;
    uint found = 0;
    for (uint b = 0; b < (uint)res.bindings.len; b++) {
        if (tree.atoms.get(res.bindings.data[b].name) != name) continue;
        if (found != 0) return 0;
        found = b + 1;
    }
    if (found == 0) return 0;
    ast::Binding* bind = &res.bindings.data[found - 1];
    if (bind.kind != ast::DeclKind.FUNC) return 0;
    ast::ScopeKind kind = res.scopes.data[bind.scope].kind;
    // A script's top-level function is a global property other code can replace.
    if (kind != ast::ScopeKind.FUNCTION && kind != ast::ScopeKind.MODULE) return 0;
    // The declaring scope encloses the loop, and nothing between them evaluates
    // code that could shadow the name.
    uint s = self.ast_fn_scope;
    for (uint steps = 0; ; steps++) {
        if (s == 0 || steps > 4096) return 0;
        if ((res.scopes.data[s].flags & (ast::SCOPE_HAS_EVAL | ast::SCOPE_CAPTURE_ALL | ast::SCOPE_HAS_WITH)) != 0) return 0;
        if (s == bind.scope) break;
        uint parent = res.scopes.data[s].parent;
        if (parent == s) return 0;
        s = parent;
    }
    uint decl = 0;
    for (uint i = 0; i < (uint)res.sites.len; i++) {
        if (res.sites.data[i].binding == found - 1) { decl = res.sites.data[i].decl; break; }
    }
    if (decl == 0 || tree.tags.data[decl] != NodeTag.FUNC_DECL) return 0;
    // Every other occurrence of the name is a call.
    uint idents = 0;
    uint calls = 0;
    for (uint i = 1; i < tree.node_count(); i++) {
        NodeTag tag = tree.tags.data[i];
        if (tag == NodeTag.IDENT && tree.atoms.get(tree.lhs.data[i]) == name) idents++;
        if (tag == NodeTag.CALL) {
            uint callee = tree.lhs.data[i];
            if (tree.tags.data[callee] == NodeTag.IDENT && tree.atoms.get(tree.lhs.data[callee]) == name) calls++;
        }
    }
    return idents == calls + 1 ? decl : 0;
}

// Collects the generator's own names into `st` and checks the body shape the
// header describes.
fn bool CompilerContext.fuse_generator_closed(&self, uint decl, FuseState* st) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[decl];
    uint fnf = tree.field(rec, ast::FN_FLAGS);
    if ((fnf & ast::FNF_GENERATOR) == 0 || (fnf & ast::FNF_ASYNC) != 0
        || (fnf & ast::FNF_SIMPLE_PARAMS) == 0) return false;
    uint params = tree.field(rec, ast::FN_PARAMS);
    for (uint i = 0; i < tree.list_len(params); i++) {
        uint p = tree.list_item(params, i);
        if (tree.tags.data[p] != NodeTag.IDENT) return false;
        st.names.push(tree.atoms.get(tree.lhs.data[p]));
    }
    uint first = tree.lhs.data[decl] + 1;
    uint yields = 0;
    uint stmt_yields = 0;
    for (uint i = first; i < decl; i++) {
        switch (tree.tags.data[i]) {
            case FUNC_EXPR: case ARROW: case CLASS_EXPR: case CLASS_DECL: case FUNC_DECL:
            case THIS: case NEW_TARGET: case SUPER_MEMBER: case SUPER_INDEX: case SUPER_CALL:
            case YIELD_STAR: case AWAIT: case TRY: case WITH: case LABELED:
            case IMPORT_CALL: case IMPORT_META: case FOR_IN: case FOR_OF:
            case OBJECT: case ARRAY_PAT: case OBJECT_PAT: case PRIVATE_MEMBER: case PRIVATE_IN:
                return false;
            case VAR_DECL:
                if ((tree.flags.data[i] & ast::VAR_KIND_MASK) == ast::VAR_KIND_VAR) return false;
                uint decls = tree.lhs.data[i];
                for (uint d = 0; d < tree.list_len(decls); d++) {
                    uint target = tree.lhs.data[tree.list_item(decls, d)];
                    if (tree.tags.data[target] != NodeTag.IDENT) return false;
                    st.names.push(tree.atoms.get(tree.lhs.data[target]));
                }
            case YIELD:
                yields++;
            case EXPR_STMT:
                if (tree.tags.data[tree.lhs.data[i]] == NodeTag.YIELD) stmt_yields++;
            default:
                break;
        }
    }
    if (yields == 0 || yields != stmt_yields || yields > FUSE_MAX_YIELDS) return false;
    for (uint i = first; i < decl; i++) {
        if (tree.tags.data[i] != NodeTag.IDENT) continue;
        char[] id = tree.atoms.get(tree.lhs.data[i]);
        bool own = false;
        foreach (n : st.names) { if (n == id) { own = true; break; } }
        if (!own) return false;
    }
    return true;
}

// Generates the for-of `n` as a fused generator when its head and callee
// qualify. Returns false, having emitted nothing, otherwise.
fn bool? CompilerContext.gen_fused_generator(&self, uint n, char[] name, bool constant, uint call,
                                            uint body, uint saved_scope, ushort saved_reg) {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.fuse_depth >= 32 || self.disable_optimize || self.capture_all || self.eval_mode || self.in_with()) return false;
    if (tree.tags.data[call] != NodeTag.CALL || (tree.flags.data[call] & ast::FLAG_OPTIONAL) != 0) return false;
    uint callee = tree.lhs.data[call];
    if (tree.tags.data[callee] != NodeTag.IDENT) return false;
    foreach (label : self.labels) {
        if (label.is_loop && label.loop_index == self.loop_depth()) return false;
    }
    if (self.is_captured_name(name)) return false;
    uint args = tree.rhs.data[call];
    for (uint i = 0; i < tree.list_len(args); i++) {
        if (tree.tags.data[tree.list_item(args, i)] == NodeTag.SPREAD) return false;
    }
    uint decl = self.fuse_find_generator(tree.atoms.get(tree.lhs.data[callee]));
    if (decl == 0) return false;
    FuseState st;
    st.depth = (char)(self.fuse_depth + 1);
    st.names.init(mem);
    st.exits.init(mem);
    defer { st.names.free(); st.exits.free(); }
    if (!self.fuse_generator_closed(decl, &st)) return false;

    uint rec = tree.rhs.data[decl];
    uint params = tree.field(rec, ast::FN_PARAMS);
    uint nparams = tree.list_len(params);
    FuseState* outer = self.fuse;
    self.push_scope_marker();
    // Parameters bind in the call's frame, after their arguments run in the caller's scope.
    self.fuse = &st;
    ushort[FUSE_MAX_PARAMS] param_regs;
    if (nparams > FUSE_MAX_PARAMS) {
        self.fuse = outer;
        self.pop_scope_to(saved_scope);
        return false;
    }
    for (uint i = 0; i < nparams; i++) {
        param_regs[i] = self.declare_var(self.fuse_name(tree.atoms.get(tree.lhs.data[tree.list_item(params, i)])), LET);
    }
    self.fuse = outer;
    for (uint i = 0; i < tree.list_len(args); i++) {
        Val v = self.gen_expr(tree.list_item(args, i), 0)!;
        if (i < nparams) self.emit_abc(Opcode.LDREG, (uint)param_regs[i], (uint)v.reg, 0);
        self.free_val(v);
    }
    self.fuse = &st;
    for (uint i = 0; i < nparams; i++) {
        if (i >= tree.list_len(args)) self.emit_abc(Opcode.LDUNDEF, (uint)param_regs[i], 0, 0);
        char[] pname = self.fuse_name(tree.atoms.get(tree.lhs.data[tree.list_item(params, i)]));
        self.emit_var_store(param_regs[i], self.add_string_constant(pname), true, false);
    }
    self.fuse = outer;
    st.binding = self.declare_var(name, constant ? CONST : LET);
    st.name_idx = self.add_string_constant(name);
    st.constant = constant;
    st.body = body;
    self.emit_abc(Opcode.LDUNDEF, (uint)st.binding, 0, 0);

    self.fuse = &st;
    self.fuse_depth++;
    defer self.fuse_depth--;
    st.renaming = true;
    st.lex_base = self.cur_lex_depth;
    self.gen_block(tree.field(rec, ast::FN_BODY), false)!;
    st.renaming = false;
    self.fuse = outer;
    foreach (exit : st.exits) self.patch_jump(exit);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
    return true;
}

// `yield v;` in fused generator code: bind the loop variable and run the body.
fn void? CompilerContext.gen_fused_yield(&self, uint y) {
    ast::Ast* tree = &ast::index_state.tree;
    FuseState* st = self.fuse;
    uint operand = tree.lhs.data[y];
    if (operand != 0) {
        Val v = self.gen_expr(operand, 0)!;
        self.emit_abc(Opcode.LDREG, (uint)st.binding, (uint)v.reg, 0);
        self.free_val(v);
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)st.binding, 0, 0);
    }
    self.emit_var_store(st.binding, st.name_idx, true, st.constant);
    self.fuse = null;
    self.push_loop(0, true);
    self.gen_stmt(st.body)!;
    self.gen_line_end(st.body);
    self.innermost_loop().continue_target = self.code_count;
    uint resume = self.emit_jump(Opcode.JUMP);
    // A break lands here and abandons the generator.
    self.pop_loop();
    for (int depth = self.cur_lex_depth; depth > st.lex_base; depth--) self.emit_simple(Opcode.POP_LEX);
    st.exits.push(self.emit_jump(Opcode.JUMP));
    self.patch_jump(resume);
    self.fuse = st;
}

// `return` in fused generator code ends the loop.
fn void? CompilerContext.gen_fused_return(&self, uint arg) {
    FuseState* st = self.fuse;
    if (arg != 0) self.free_val(self.gen_expr(arg, 0)!);
    for (int depth = self.cur_lex_depth; depth > st.lex_base; depth--) self.emit_simple(Opcode.POP_LEX);
    st.exits.push(self.emit_jump(Opcode.JUMP));
}
