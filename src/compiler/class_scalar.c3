module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;
import boomkat::lexer;

fn bool scalar_numeric_expr(ast::Ast* tree, uint n, ast::ScalarClass* fields, uint* budget) @local {
    if (n == 0 || *budget == 0) return false;
    (*budget)--;
    switch (tree.tags.data[n]) {
        case NUMBER:
            return true;
        case MEMBER:
            if (tree.tags.data[tree.lhs.data[n]] != NodeTag.THIS
                || (tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0) return false;
            for (uint i = 0; i < fields.field_count; i++) {
                if (fields.field_names[i] == tree.rhs.data[n]) return true;
            }
            return false;
        case BINARY:
            TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
            if (op != TokenType.PLUS && op != TokenType.MINUS
                && op != TokenType.STAR && op != TokenType.SLASH) return false;
            return scalar_numeric_expr(tree, tree.lhs.data[n], fields, budget)
                && scalar_numeric_expr(tree, tree.rhs.data[n], fields, budget);
        default:
            return false;
    }
}

fn bool scalar_constructor(ast::Ast* tree, uint class_node, ast::ScalarClass* fields) @local {
    uint rec = tree.rhs.data[class_node];
    if (tree.field(rec, ast::CLS_HERITAGE) != 0) return false;
    uint members = tree.field(rec, ast::CLS_MEMBERS);
    uint ctor = 0;
    for (uint i = 0; i < tree.list_len(members); i++) {
        uint member = tree.list_item(members, i);
        if (tree.tags.data[member] == NodeTag.EMPTY_STMT) continue;
        uint key = tree.lhs.data[member];
        if (tree.tags.data[member] != NodeTag.CLASS_METHOD
            || tree.tags.data[key] != NodeTag.STRING
            || (tree.flags.data[member] & ast::PROP_COMPUTED) != 0) return false;
        if (str_eq(tree.atoms.get(tree.lhs.data[key]), "constructor")
            && (tree.flags.data[member] & (ast::MEMBER_STATIC | ast::MEMBER_GET | ast::MEMBER_SET)) == 0) {
            ctor = tree.rhs.data[member];
        }
    }
    if (ctor == 0) return false;
    uint fn_rec = tree.rhs.data[ctor];
    uint params = tree.field(fn_rec, ast::FN_PARAMS);
    for (uint i = 0; i < tree.list_len(params); i++) {
        if (tree.tags.data[tree.list_item(params, i)] != NodeTag.IDENT) return false;
    }
    uint body = tree.field(fn_rec, ast::FN_BODY);
    uint statements = tree.lhs.data[body];
    uint count = tree.list_len(statements);
    if (count == 0 || count > 4) return false;
    for (uint i = 0; i < count; i++) {
        uint stmt = tree.list_item(statements, i);
        if (tree.tags.data[stmt] != NodeTag.EXPR_STMT) return false;
        uint assign = tree.lhs.data[stmt];
        if (tree.tags.data[assign] != NodeTag.ASSIGN) return false;
        uint target = tree.lhs.data[assign];
        uint value = tree.rhs.data[assign];
        if ((TokenType)(tree.flags.data[assign] & 0x7F) != TokenType.ASSIGN
            || tree.tags.data[target] != NodeTag.MEMBER
            || tree.tags.data[tree.lhs.data[target]] != NodeTag.THIS
            || tree.tags.data[value] != NodeTag.IDENT) return false;
        uint arg = tree.list_len(params);
        for (uint p = 0; p < tree.list_len(params); p++) {
            if (tree.lhs.data[tree.list_item(params, p)] == tree.lhs.data[value]) arg = p;
        }
        if (arg == tree.list_len(params)) return false;
        fields.field_names[i] = tree.rhs.data[target];
        fields.field_args[i] = arg;
        for (uint p = 0; p < i; p++) {
            if (fields.field_names[p] == fields.field_names[i]) return false;
        }
    }
    fields.field_count = count;
    return true;
}

fn void ensure_scalar_classes() {
    ast::AstIndex* idx = ast::index_state;
    if (idx == null || !idx.use || idx.scalar_classes_known) return;
    idx.scalar_classes_known = true;
    ast::Ast* tree = &idx.tree;
    for (uint s = 1; s < idx.res.scopes.len; s++) {
        ast::Scope scope = idx.res.scopes.data[s];
        if (scope.kind != ast::ScopeKind.CLASS || tree.tags.data[scope.node] != NodeTag.CLASS_DECL) continue;
        ast::ScalarClass fields;
        fields.class_node = scope.node;
        if (!scalar_constructor(tree, scope.node, &fields)) continue;
        uint members = tree.field(tree.rhs.data[scope.node], ast::CLS_MEMBERS);
        for (uint i = 0; i < tree.list_len(members); i++) {
            uint member = tree.list_item(members, i);
            if ((tree.flags.data[member] & ast::MEMBER_GET) == 0
                || (tree.flags.data[member] & ast::MEMBER_STATIC) != 0) continue;
            uint key = tree.lhs.data[tree.lhs.data[member]];
            bool shadowed = false;
            for (uint f = 0; f < fields.field_count; f++) {
                if (fields.field_names[f] == key) shadowed = true;
            }
            if (shadowed) continue;
            uint fn_rec = tree.rhs.data[tree.rhs.data[member]];
            uint body = tree.field(fn_rec, ast::FN_BODY);
            uint stmts = tree.lhs.data[body];
            if (tree.list_len(stmts) != 1) continue;
            uint ret = tree.list_item(stmts, 0);
            uint budget = 32;
            if (tree.tags.data[ret] != NodeTag.RETURN
                || !scalar_numeric_expr(tree, tree.lhs.data[ret], &fields, &budget)) continue;
            fields.getter_member = member;
            fields.getter_expr = tree.lhs.data[ret];
            idx.scalar_classes.push(fields);
        }
    }
}

fn void link_scalar_class(uint class_node, uint member, CompiledFunction* function) {
    if (class_node == 0 || ast::index_state == null || !ast::index_state.use) return;
    ensure_scalar_classes();
    ast::AstIndex* idx = ast::index_state;
    foreach (&fields : idx.scalar_classes.data[:idx.scalar_classes.len]) {
        if (fields.class_node != class_node || (member != 0 && fields.getter_member != member)) continue;
        uint slot = member == 0 ? 0 : 1;
        if (slot == 0) { fields.constructor = function; }
        else { fields.getter = function; }
        foreach (guard : fields.guards.data[:fields.guards.len]) {
            ((CompiledFunction*)guard).inner_funcs[slot] = function;
        }
    }
}

// Only the numeric result escapes this expression. Guard before construction;
// a miss evaluates the ordinary new/property-read arm with the staged arguments.
fn bool? CompilerContext.gen_scalar_new_member(&self, uint n, Val* result) {
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    uint new_node = tree.lhs.data[n];
    if ((tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0 || self.disable_optimize
        || self.scalar_fields != null || self.inner_func_count >= 255
        || tree.tags.data[new_node] != NodeTag.NEW
        || tree.tags.data[tree.lhs.data[new_node]] != NodeTag.IDENT) return false;
    uint args = tree.rhs.data[new_node];
    if (tree.list_len(args) > 16 || self.next_reg + tree.list_len(args) + 32 >= 256) return false;
    for (uint i = 0; i < tree.list_len(args); i++) {
        if (tree.tags.data[tree.list_item(args, i)] == NodeTag.SPREAD) return false;
    }
    ensure_scalar_classes();
    uint name = tree.lhs.data[tree.lhs.data[new_node]];
    ast::ScalarClass* fields = null;
    foreach (&candidate : idx.scalar_classes.data[:idx.scalar_classes.len]) {
        uint class_id = tree.lhs.data[candidate.class_node];
        if (class_id == 0 || tree.lhs.data[class_id] != name
            || tree.lhs.data[tree.lhs.data[candidate.getter_member]] != tree.rhs.data[n]) continue;
        fields = candidate;
        break;
    }
    if (fields == null) return false;
    CompilerContext guard_ctx;
    guard_ctx.init(self.lexer, self.heap);
    defer guard_ctx.cleanup();
    guard_ctx.add_string_constant(tree.atoms.get(tree.rhs.data[n]));
    guard_ctx.inner_func_count = 2;
    guard_ctx.inner_funcs[0] = (CompiledFunction*)fields.constructor;
    guard_ctx.inner_funcs[1] = (CompiledFunction*)fields.getter;
    guard_ctx.emit_simple(Opcode.RETUNDEF);
    // Reuse template lifetime and cache ownership for the guarded identities.
    CompiledFunction* guard = guard_ctx.finish()!;
    fields.guards.push(guard);
    uint guard_index = self.add_inner_func(guard);
    Val callee = self.gen_new(new_node)!;
    Instruction construct = self.code[--self.code_count];
    self.next_reg = (ushort)(callee.reg + 2 + construct.c);
    if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    ushort out = self.alloc_reg();
    self.emit_abc(Opcode.CLASS_SCALAR_GUARD, callee.reg, construct.c, guard_index);
    uint slow = self.emit_cond_jump(Opcode.IF_FALSE, callee.reg + 1);
    self.scalar_fields = fields;
    self.scalar_first_arg = callee.reg + 2;
    Val value = self.gen_expr(fields.getter_expr, 0)!;
    self.scalar_fields = null;
    self.emit_abc(Opcode.LDREG, out, value.reg, 0);
    uint done = self.emit_jump(Opcode.JUMP);
    self.patch_jump(slow);
    self.emit_abc(Opcode.NEW_OBJ, construct.a, construct.b, construct.c);
    uint key = self.add_string_constant(tree.atoms.get(tree.rhs.data[n]));
    self.emit_abc(Opcode.GETPROPC, out, callee.reg, key);
    self.patch_jump(done);
    self.free_regs_to(out + 1);
    self.call_prop_obj_reg = REG_NONE;
    self.gen_line_end(n);
    *result = { out, false, 0 };
    return true;
}
