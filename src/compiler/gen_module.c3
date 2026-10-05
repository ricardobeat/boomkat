module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;

fn uint CompilerContext.gen_module_request(&self, uint rec, bool deferred = false) {
    ast::Ast* tree = &ast::index_state.tree;
    ModuleAttrType type = NONE;
    uint attrs = tree.field(rec, ast::REQ_ATTRS);
    for (uint i = 0; i < tree.list_len(attrs); i += 2) {
        if (!str_eq(tree.atoms.get(tree.list_item(attrs, i)), "type")) continue;
        char[] value = tree.atoms.get(tree.list_item(attrs, i + 1));
        if (str_eq(value, "json")) type = JSON;
        if (str_eq(value, "text")) type = TEXT;
        if (str_eq(value, "bytes")) type = BYTES;
    }
    return mod_register_req_module(self.get_module_def(), self.gen_name(tree.field(rec, ast::REQ_SOURCE)), type, deferred);
}

fn void? CompilerContext.gen_export_pattern(&self, uint n, bool lexical) {
    if (n == 0) return;
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    switch (tree.tags.data[n]) {
        case IDENT:
            char[] name = self.gen_name(tree.lhs.data[n]);
            self.register_export(self.get_module_def(), name, name, false, 0, lexical, true)!;
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint list = tree.lhs.data[n];
            for (uint i = 0; i < tree.list_len(list); i++) self.gen_export_pattern(tree.list_item(list, i), lexical)!;
        case PAT_PROP:
            self.gen_export_pattern((tree.flags.data[n] & ast::PROP_SHORTHAND_PAT) != 0 ? tree.lhs.data[n] : tree.rhs.data[n], lexical)!;
        case REST:
        case ASSIGN_PAT:
            self.gen_export_pattern(tree.lhs.data[n], lexical)!;
        default: break;
    }
}

fn bool CompilerContext.gen_module_lexical(&self, uint atom) {
    ast::Resolver* res = &ast::index_state.res;
    uint b = res.lookup(1, atom);
    if (b == 0) return false;
    ast::DeclKind kind = res.bindings.data[b].kind;
    return kind == ast::DeclKind.LET || kind == ast::DeclKind.CONST || kind == ast::DeclKind.CLASS;
}

fn void? CompilerContext.gen_module_metadata(&self, uint stmts) {
    ast::Ast* tree = &ast::index_state.tree;
    CompModuleDef* mod = self.get_module_def();
    // Requests retain source order; imports are all visible when exports are classified.
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint n = tree.list_item(stmts, i);
        switch (tree.tags.data[n]) {
            case IMPORT_DECL:
                bool deferred = (tree.flags.data[n] & ast::IMPORT_PHASE_DEFER) != 0;
                bool source = (tree.flags.data[n] & ast::IMPORT_PHASE_SOURCE) != 0;
                uint req = self.gen_module_request(tree.lhs.data[n], deferred);
                uint specs = tree.rhs.data[n];
                for (uint j = 0; j < tree.list_len(specs); j++) {
                    uint sp = tree.list_item(specs, j);
                    char[] imported = self.gen_name(tree.lhs.data[sp]);
                    char[] local = self.gen_name(tree.lhs.data[tree.rhs.data[sp]]);
                    mod_register_import(mod, local, source ? SOURCE_BINDING : imported, req,
                        (tree.flags.data[sp] & ast::IMPORT_NAMESPACE) != 0, str_eq(imported, "default") && !source, deferred, source);
                }
            case EXPORT_NAMED:
                if (tree.rhs.data[n] != 0) self.gen_module_request(tree.rhs.data[n]);
            case EXPORT_ALL:
                self.gen_module_request(tree.lhs.data[n]);
            default: break;
        }
    }
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint n = tree.list_item(stmts, i);
        switch (tree.tags.data[n]) {
            case EXPORT_ALL:
                uint req = self.gen_module_request(tree.lhs.data[n]);
                if (tree.rhs.data[n] == 0) { mod_register_star_export(mod, req); }
                else { self.register_export(mod, "*", self.gen_name(tree.rhs.data[n]), true, req)!; }
            case EXPORT_NAMED:
                uint specs = tree.lhs.data[n];
                bool indirect = tree.rhs.data[n] != 0;
                uint req = indirect ? self.gen_module_request(tree.rhs.data[n]) : 0;
                for (uint j = 0; j < tree.list_len(specs); j++) {
                    uint sp = tree.list_item(specs, j);
                    char[] local = self.gen_name(tree.lhs.data[sp]);
                    char[] exported = self.gen_name(tree.rhs.data[sp]);
                    CompImportEntry* imported = indirect ? null : mod_find_import_by_local(mod, local);
                    if (imported != null && !(imported.is_star && imported.is_deferred)) {
                        self.register_export(mod, imported.is_star ? "*" : imported.import_name, exported, true, imported.req_module_idx)!;
                    } else {
                        self.register_export(mod, local, exported, indirect, req, self.gen_module_lexical(tree.lhs.data[sp]))!;
                    }
                }
            case EXPORT_DECL:
                uint decl = tree.lhs.data[n];
                if (tree.tags.data[decl] == ast::NodeTag.VAR_DECL) {
                    uint list = tree.lhs.data[decl];
                    bool lexical = (tree.flags.data[decl] & ast::VAR_KIND_MASK) != ast::VAR_KIND_VAR;
                    for (uint j = 0; j < tree.list_len(list); j++) self.gen_export_pattern(tree.lhs.data[tree.list_item(list, j)], lexical)!;
                } else {
                    self.gen_export_pattern(tree.lhs.data[decl], tree.tags.data[decl] == ast::NodeTag.CLASS_DECL)!;
                }
            case EXPORT_DEFAULT:
                uint value = tree.lhs.data[n];
                bool declaration = (tree.flags.data[n] & ast::EXPORT_DEFAULT_EXPR) == 0;
                bool function = declaration && tree.tags.data[value] == ast::NodeTag.FUNC_DECL;
                uint id = declaration ? tree.lhs.data[value] : 0;
                char[] local = id != 0 ? self.gen_name(tree.lhs.data[id]) : "*default*";
                if (function && id == 0) {
                    NameEvalFrame names = self.save_name_eval();
                    defer self.restore_name_eval(names);
                    self.has_inferred_name = true;
                    self.inferred_name = "default";
                    mod_register_func_decl(mod, local, self.add_inner_func(self.gen_compile_function(value)!));
                }
                self.register_export(mod, local, "default", false, 0, !function, true)!;
            default: break;
        }
    }
}

fn void CompilerContext.gen_module_slots(&self) {
    ast::AstIndex* idx = ast::index_state;
    if ((idx.res.scopes.data[1].flags & (ast::SCOPE_HAS_EVAL | ast::SCOPE_CAPTURE_ALL | ast::SCOPE_HAS_WITH)) != 0) return;
    CompModuleDef* mod = self.get_module_def();
    for (uint i = idx.res.func_start.data[1]; i < idx.res.func_start.data[2]; i++) {
        ast::Binding* b = &idx.res.bindings.data[idx.res.func_items.data[i]];
        if (b.scope != 1 || b.kind != ast::DeclKind.VAR || b.captured) continue;
        char[] name = self.gen_name(b.name);
        bool exported = false;
        foreach (entry : mod.exports) exported |= !entry.is_indirect && str_eq(entry.local_name, name);
        if (!exported) self.slot_global_name_idxs.push(self.add_string_constant(name));
    }
}
