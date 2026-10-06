module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;
import boomkat::lexer;

fn uint flat_template_parts(ast::Ast* tree, uint node, uint depth, bool* nested) {
    if (depth > 4) return 33;
    uint parts = tree.lhs.data[node];
    uint count = 0;
    uint expressions = tree.template_exprs(parts);
    for (uint i = 0; i <= expressions; i++) {
        if (tree.atoms.get(tree.template_cooked(parts, i)).len != 0 || expressions == 0) count++;
        if (i == expressions) break;
        uint value = tree.template_expr(parts, i);
        if (tree.tags.data[value] == NodeTag.TEMPLATE) {
            *nested = true;
            count += flat_template_parts(tree, value, depth + 1, nested);
        } else { count++; }
        if (count > 32) return count;
    }
    return count;
}

fn void? CompilerContext.emit_flat_template(&self, uint node, ushort first, uint* position, ushort scratch, bool inner) {
    ast::Ast* tree = &ast::index_state.tree;
    uint parts = tree.lhs.data[node];
    uint expressions = tree.template_exprs(parts);
    uint start = *position;
    for (uint i = 0; i <= expressions; i++) {
        char[] text = tree.atoms.get(tree.template_cooked(parts, i));
        self.gen_line(tree.template_tok(parts, i));
        if (text.len != 0 || expressions == 0) self.emit_a_bc(Opcode.LDCONST, first + (*position)++, self.add_string_constant(text));
        if (i == expressions) break;
        uint value = tree.template_expr(parts, i);
        if (tree.tags.data[value] == NodeTag.TEMPLATE) {
            self.emit_flat_template(value, first, position, scratch, true)!;
        } else {
            uint code_start = self.code_count;
            Val result = self.gen_expr(value, 0)!;
            bool defer_string = (i + 1 == expressions && tree.atoms.get(tree.template_cooked(parts, i + 1)).len == 0)
                || self.part_producer_kind(code_start, self.code_count, result.reg, 0) == PartKind.PART_DEFER;
            if (!defer_string) result.reg = self.tostr_into_temp(result.reg);
            self.emit_abc(Opcode.LDREG, first + (*position)++, result.reg, 0);
            self.free_regs_to(scratch + 1);
        }
    }
    // Validate an inner join before later substitutions can run user code.
    if (inner) self.emit_abc(Opcode.STRJOIN_LENGTH, scratch, first + start, *position - start);
}

fn bool? CompilerContext.gen_flat_template(&self, uint node, Val* result) {
    if (self.disable_optimize) return false;
    bool nested = false;
    uint count = flat_template_parts(&ast::index_state.tree, node, 0, &nested);
    if (!nested || count > 32 || self.next_reg + count + 16 >= 256) return false;
    ushort first = self.next_reg;
    for (uint i = 0; i < count; i++) self.alloc_persistent_reg();
    ushort scratch = self.alloc_persistent_reg();
    uint position = 0;
    self.emit_flat_template(node, first, &position, scratch, false)!;
    self.emit_abc(Opcode.STRJOIN, first, first, count);
    self.free_regs_to(first + 1);
    *result = (Val){ first, false, 0 };
    return true;
}

fn bool? CompilerContext.gen_concat_join(&self, uint node, Val* result) {
    if (self.disable_optimize) return false;
    ast::Ast* tree = &ast::index_state.tree;
    uint[8] rights;
    uint count = 0;
    uint cursor = node;
    while (tree.tags.data[cursor] == NodeTag.BINARY
        && (TokenType)(tree.flags.data[cursor] & 0x7F) == TokenType.PLUS) {
        if (count == 8) return false;
        rights[count++] = tree.rhs.data[cursor];
        cursor = tree.lhs.data[cursor];
    }
    if (count < 2 || tree.tags.data[cursor] != NodeTag.STRING || self.next_reg + count + 16 >= 256) return false;
    ushort first = self.next_reg;
    for (uint i = 0; i <= count; i++) self.alloc_persistent_reg();
    ushort scratch = self.alloc_persistent_reg();
    self.emit_a_bc(Opcode.LDCONST, first, self.add_string_constant(tree.atoms.get(tree.lhs.data[cursor])));
    for (uint i = 0; i < count; i++) {
        Val value = self.gen_expr(rights[count - 1 - i], 0)!;
        ushort slot = (ushort)(first + i + 1);
        self.emit_abc(Opcode.LDREG, slot, value.reg, 0);
        self.emit_abc(Opcode.TOSTR_ADD, slot, 0, 0);
        self.free_regs_to(scratch + 1);
        if (i + 1 < count) self.emit_abc(Opcode.STRJOIN_LENGTH, scratch, first, i + 2);
    }
    self.emit_abc(Opcode.STRJOIN, first, first, count + 1);
    self.free_regs_to(first + 1);
    *result = (Val){ first, false, 0 };
    return true;
}
