module boomkat::compiler;

import boomkat::ast;

struct PropertyConstant {
    uint atom;
    uint uses;
}

// Reserve a few narrow constant indices before bindings and literals consume
// them. Existing emission still assigns every operand and metadata index.
fn void CompilerContext.seed_property_constants(&self, uint node, uint start) @noinline {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.disable_optimize || self.fuse != null || self.const_count > 128
        || tree.end_tok.data[node] - start < 4096) return;

    PropertyConstant[128] keys;
    uint count = 0;
    uint n = node;
    while (n > 1) {
        n--;
        if (tree.end_tok.data[n] < start) break;
        ast::NodeTag tag = tree.tags.data[n];
        if (tag == ast::NodeTag.FUNC_EXPR || tag == ast::NodeTag.FUNC_DECL
            || tag == ast::NodeTag.ARROW) {
            // Nodes are appended after their children and last source token.
            // Skip a nested function's nodes; its context seeds its own keys.
            uint inner_start = tree.field(tree.rhs.data[n], ast::FN_SRC_START);
            while (n > 1 && tree.end_tok.data[n - 1] >= inner_start) n--;
            continue;
        }
        if (tag != ast::NodeTag.MEMBER) continue;
        uint atom = tree.rhs.data[n];
        uint k = 0;
        while (k < count && keys[k].atom != atom) k++;
        if (k < count) {
            keys[k].uses++;
        } else if (count < keys.len) {
            keys[count++] = { atom, 1 };
        }
    }

    // Bound the reserved prefix so name-based call operands retain room too.
    for (uint i = 0; i < 32 && i < count; i++) {
        uint best = i;
        for (uint k = i + 1; k < count; k++) {
            if (keys[k].uses > keys[best].uses) best = k;
        }
        PropertyConstant key = keys[best];
        keys[best] = keys[i];
        keys[i] = key;
        self.add_string_constant(tree.atoms.get(key.atom));
    }
}
