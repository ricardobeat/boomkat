module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;

// Retain the selected value while later initializers run, including overwritten keys.
fn bool? CompilerContext.gen_literal_member(&self, uint node, Val* result) {
    ast::Ast* tree = &ast::index_state.tree;
    uint selected_key = tree.rhs.data[node];
    if (tree.tags.data[node] != NodeTag.MEMBER) {
        $if $feat(PROTO_TAGGED_LOOPS):
            if (tree.tags.data[node] != NodeTag.INDEX) return false;
            uint key = tree.rhs.data[node];
            if (tree.tags.data[key] != NodeTag.STRING) return self.gen_literal_array_index(node, result);
            selected_key = tree.lhs.data[key];
        $else
            return false;
        $endif
    }
    if (self.disable_optimize || tree.tags.data[tree.lhs.data[node]] != NodeTag.OBJECT) return false;
    uint items = tree.lhs.data[tree.lhs.data[node]];
    uint count = tree.list_len(items);
    if (count == 0 || count > 16) return false;
    uint selected = count;
    for (uint i = 0; i < count; i++) {
        uint property = tree.list_item(items, i);
        uint key = tree.lhs.data[property];
        if (tree.tags.data[property] != NodeTag.PROP_INIT || (tree.flags.data[property] & ast::PROP_COMPUTED) != 0
            || tree.tags.data[key] != NodeTag.STRING || tree.atoms.get(tree.lhs.data[key]) == "__proto__") return false;
        if (tree.lhs.data[key] == selected_key) selected = i;
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
        // Projection must not turn an initializer call into a proper tail call.
        self.emit_simple(Opcode.NOP);
        if (i == selected) self.emit_abc(Opcode.LDREG, out, value.reg, 0);
        self.free_regs_to(floor);
    }
    *result = (Val){ out, false, 0 };
    self.call_prop_obj_reg = REG_NONE;
    return true;
}

// The index is a primitive literal, so evaluating it cannot run user code.
// Preserve every element initializer in order even though the container vanishes.
fn bool? CompilerContext.gen_literal_array_index(&self, uint node, Val* result) {
    ast::Ast* tree = &ast::index_state.tree;
    uint array = tree.lhs.data[node];
    uint key = tree.rhs.data[node];
    if (self.disable_optimize || tree.tags.data[array] != NodeTag.ARRAY
        || tree.tags.data[key] != NodeTag.NUMBER) return false;
    ulong bits = ((ulong)tree.rhs.data[key] << 32) | tree.lhs.data[key];
    double index = bitcast(bits, double);
    uint list = tree.lhs.data[array];
    uint count = tree.list_len(list);
    if (!(index >= 0 && index < count) || count > 16 || index != (double)(uint)index) return false;
    for (uint i = 0; i < count; i++) {
        uint element = tree.list_item(list, i);
        if (element == 0 || tree.tags.data[element] == NodeTag.SPREAD) return false;
    }
    ushort out = self.alloc_persistent_reg();
    ushort floor = self.next_reg;
    for (uint i = 0; i < count; i++) {
        Val value = self.gen_expr(tree.list_item(list, i), 0)!;
        self.emit_simple(Opcode.NOP);
        if (i == (uint)index) self.emit_abc(Opcode.LDREG, out, value.reg, 0);
        self.free_regs_to(floor);
    }
    *result = (Val){ out, false, 0 };
    self.call_prop_obj_reg = REG_NONE;
    return true;
}
