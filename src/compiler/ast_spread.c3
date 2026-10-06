module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;

// The two-statement shape proves that the uncaptured container has one read.
// Keep its lexical binding and substitute only that read with the projected value.
fn bool? CompilerContext.gen_projection_block(&self, uint statements) {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.disable_optimize || self.projection_node != 0 || tree.list_len(statements) != 2
        || self.has_direct_eval || self.has_with_stmt || self.outer_with || self.has_captured_local) return false;
    uint declaration = tree.list_item(statements, 0);
    uint use = tree.list_item(statements, 1);
    if (tree.tags.data[declaration] != NodeTag.VAR_DECL
        || (tree.flags.data[declaration] & ast::VAR_KIND_MASK) != ast::VAR_KIND_CONST
        || tree.list_len(tree.lhs.data[declaration]) != 1 || tree.tags.data[use] != NodeTag.EXPR_STMT) return false;
    uint binding = tree.list_item(tree.lhs.data[declaration], 0);
    uint name = tree.lhs.data[binding];
    uint init = tree.rhs.data[binding];
    uint assignment = tree.lhs.data[use];
    if (tree.tags.data[name] != NodeTag.IDENT || tree.tags.data[assignment] != NodeTag.ASSIGN
        || tree.tags.data[tree.lhs.data[assignment]] != NodeTag.IDENT
        || tree.lhs.data[tree.lhs.data[assignment]] == tree.lhs.data[name]) return false;
    uint member = tree.rhs.data[assignment];
    if (tree.tags.data[member] != NodeTag.MEMBER || (tree.flags.data[member] & ast::FLAG_OPTIONAL) != 0
        || tree.tags.data[tree.lhs.data[member]] != NodeTag.IDENT
        || tree.lhs.data[tree.lhs.data[member]] != tree.lhs.data[name]) return false;
    bool array = tree.tags.data[init] == NodeTag.ARRAY;
    if (!array && tree.tags.data[init] != NodeTag.OBJECT) return false;
    uint items = tree.lhs.data[init];
    uint count = tree.list_len(items);
    if (count == 0 || count > 4) return false;
    uint spread = tree.list_item(items, 0);
    if (tree.tags.data[spread] != (array ? NodeTag.SPREAD : NodeTag.PROP_SPREAD)) return false;
    if (array && tree.atoms.get(tree.rhs.data[member]) != "length") return false;
    for (uint i = 1; i < count; i++) {
        uint item = tree.list_item(items, i);
        uint expression = item;
        if (!array) {
            bool shorthand = tree.tags.data[item] == NodeTag.PROP_SHORTHAND && tree.rhs.data[item] == 0;
            if (!shorthand && (tree.tags.data[item] != NodeTag.PROP_INIT || (tree.flags.data[item] & ast::PROP_COMPUTED) != 0
                || tree.tags.data[tree.lhs.data[item]] != NodeTag.STRING)) return false;
            uint key = tree.lhs.data[tree.lhs.data[item]];
            if (key == tree.rhs.data[member] || tree.atoms.get(key) == "__proto__") return false;
            expression = shorthand ? tree.lhs.data[item] : tree.rhs.data[item];
        }
        // Restrict tail expressions so they cannot observe or capture the projected binding.
        if (expression == 0 || (tree.tags.data[expression] != NodeTag.IDENT && tree.tags.data[expression] != NodeTag.NUMBER)) return false;
        if (tree.tags.data[expression] == NodeTag.IDENT && tree.lhs.data[expression] == tree.lhs.data[name]) return false;
    }
    uint source = tree.lhs.data[spread];
    if (tree.tags.data[source] != NodeTag.IDENT || tree.lhs.data[source] == tree.lhs.data[name]) return false;
    uint key = self.add_string_constant(tree.atoms.get(tree.rhs.data[member]));
    if (key >= 255) return false;
    self.projection_node = init;
    self.projection_key = array ? 255 : key;
    defer { self.projection_node = 0; self.projection_source = 0; }
    self.gen_stmt(declaration)!;
    self.projection_member = member;
    defer self.projection_member = 0;
    self.gen_stmt(use)!;
    return true;
}

fn Val? CompilerContext.gen_spread_projection(&self, uint node) {
    ast::Ast* tree = &ast::index_state.tree;
    uint items = tree.lhs.data[node];
    uint source = tree.lhs.data[tree.list_item(items, 0)];
    bool array = tree.tags.data[node] == NodeTag.ARRAY;
    ushort out = self.alloc_persistent_reg();
    self.alloc_persistent_reg();
    ushort saved_source = self.alloc_persistent_reg();
    // Reuse this value on guard failure: resolving the identifier can invoke a getter.
    Val value = self.gen_expr(source, 0)!;
    self.emit_abc(Opcode.LDREG, saved_source, value.reg, 0);
    self.emit_abc(Opcode.SPREAD_PROJECTION, out, saved_source, self.projection_key);
    uint slow = self.emit_cond_jump(Opcode.IF_FALSE, out + 1);
    for (uint i = 1; i < tree.list_len(items); i++) {
        uint item = tree.list_item(items, i);
        uint expression = array ? item : tree.tags.data[item] == NodeTag.PROP_SHORTHAND ? tree.lhs.data[item] : tree.rhs.data[item];
        self.free_val(self.gen_expr(expression, 0)!);
    }
    if (array && tree.list_len(items) > 1) self.emit_abc(Opcode.ADDI, out, out, tree.list_len(items) - 1);
    uint done = self.emit_jump(Opcode.JUMP);
    self.patch_jump(slow);
    self.projection_node = 0;
    self.projection_source = source;
    self.projection_source_reg = saved_source;
    Val materialized = self.gen_expr(node, 0)!;
    self.projection_source = 0;
    uint key = array ? self.add_string_constant("length") : self.projection_key;
    self.emit_abc(Opcode.GETPROPC, out, materialized.reg, key);
    self.patch_jump(done);
    self.free_regs_to(out + 1);
    return (Val){ out, false, 0 };
}
