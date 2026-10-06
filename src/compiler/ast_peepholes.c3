module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;

// Retain the selected value while later initializers run, including overwritten keys.
fn bool? CompilerContext.gen_literal_member(&self, uint node, Val* result) {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.disable_optimize || tree.tags.data[node] != NodeTag.MEMBER
        || tree.tags.data[tree.lhs.data[node]] != NodeTag.OBJECT) return false;
    uint items = tree.lhs.data[tree.lhs.data[node]];
    uint count = tree.list_len(items);
    if (count == 0 || count > 16) return false;
    uint selected = count;
    for (uint i = 0; i < count; i++) {
        uint property = tree.list_item(items, i);
        uint key = tree.lhs.data[property];
        if (tree.tags.data[property] != NodeTag.PROP_INIT || (tree.flags.data[property] & ast::PROP_COMPUTED) != 0
            || tree.tags.data[key] != NodeTag.STRING || tree.atoms.get(tree.lhs.data[key]) == "__proto__") return false;
        if (tree.lhs.data[key] == tree.rhs.data[node]) selected = i;
    }
    if (selected == count) return false;
    ushort out = self.alloc_persistent_reg();
    ushort floor = self.next_reg;
    for (uint i = 0; i < count; i++) {
        uint property = tree.list_item(items, i);
        NameEvalFrame names = self.save_name_eval();
        defer self.restore_name_eval(names);
        self.has_inferred_name = true;
        self.inferred_name = tree.atoms.get(tree.lhs.data[tree.lhs.data[property]]);
        Val value = self.gen_expr(tree.rhs.data[property], 0)!;
        if (i == selected) self.emit_abc(Opcode.LDREG, out, value.reg, 0);
        self.free_regs_to(floor);
    }
    *result = (Val){ out, false, 0 };
    self.call_prop_obj_reg = REG_NONE;
    return true;
}
