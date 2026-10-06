module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;
import boomkat::lexer;

struct InlineValue { uint name; uint key; ushort reg; }
struct InlineValues {
    InlineValue[32] values;
    uint count;
    ushort receiver;
    bool method;
}
struct InlineArg {
    uint node;
    uint count;
    uint[16] expressions;
    uint[16] keys;
    ushort[16] registers;
    bool object;
    bool array;
}

fn bool inline_substitution(ast::Ast* tree, uint node, InlineValues* values, Val* result) {
    if (tree.tags.data[node] == NodeTag.THIS && values.method) {
        *result = (Val){ values.receiver, true, values.receiver };
        return true;
    }
    uint name;
    uint key = 0;
    if (tree.tags.data[node] == NodeTag.IDENT) { name = tree.lhs.data[node]; }
    else if (tree.tags.data[node] == NodeTag.MEMBER && tree.tags.data[tree.lhs.data[node]] == NodeTag.IDENT) {
        name = tree.lhs.data[tree.lhs.data[node]];
        key = tree.rhs.data[node] + 1;
    } else { return false; }
    for (uint i = 0; i < values.count; i++) {
        InlineValue value = values.values[i];
        if (value.name == name && value.key == key) {
            *result = (Val){ value.reg, true, value.reg };
            return true;
        }
    }
    return false;
}

fn void link_inline_function(uint node, CompiledFunction* function) {
    ast::AstIndex* idx = ast::index_state;
    if (idx.res.scopes.len > 128 || idx.tree.tags.len > 8192) return;
    foreach (&link : idx.inline_links.data[:idx.inline_links.len]) {
        if (link.node != node) continue;
        link.target = function;
        foreach (guard : link.guards.data[:link.guards.len]) ((CompiledFunction*)guard).inner_funcs[0] = function;
        return;
    }
    idx.inline_links.push((ast::InlineLink){ .node = node, .target = function });
}

fn bool inline_expression(ast::Ast* tree, uint node, InlineValues* values, uint* budget) {
    if (node == 0 || *budget == 0) return false;
    (*budget)--;
    Val ignored;
    if (inline_substitution(tree, node, values, &ignored)) return true;
    if (tree.tags.data[node] == NodeTag.NUMBER) return true;
    if (tree.tags.data[node] == NodeTag.MEMBER && values.method
        && tree.tags.data[tree.lhs.data[node]] == NodeTag.THIS
        && (tree.flags.data[node] & ast::FLAG_OPTIONAL) == 0) return true;
    if (tree.tags.data[node] != NodeTag.BINARY) return false;
    TokenType op = (TokenType)(tree.flags.data[node] & 0x7F);
    return (op == TokenType.PLUS || op == TokenType.MINUS || op == TokenType.STAR || op == TokenType.SLASH)
        && inline_expression(tree, tree.lhs.data[node], values, budget)
        && inline_expression(tree, tree.rhs.data[node], values, budget);
}

fn bool inline_bind(InlineValues* values, uint name, uint key, ushort reg) {
    if (values.count == 32) return false;
    for (uint i = 0; i < values.count; i++) {
        if (values.values[i].name == name && values.values[i].key == key) return false;
    }
    values.values[values.count++] = (InlineValue){ name, key, reg };
    return true;
}

fn bool inline_argument(ast::Ast* tree, uint parameter, uint argument, InlineArg* out, InlineValues* values) {
    out.node = argument;
    NodeTag tag = tree.tags.data[argument];
    out.object = tag == NodeTag.OBJECT;
    out.array = tag == NodeTag.ARRAY;
    if (tag == NodeTag.SPREAD) return false;
    if (!out.object && !out.array) {
        if (tree.tags.data[parameter] != NodeTag.IDENT) return false;
        out.count = 1;
        out.expressions[0] = argument;
        return inline_bind(values, tree.lhs.data[parameter], 0, (ushort)values.count);
    }
    uint items = tree.lhs.data[argument];
    out.count = tree.list_len(items);
    if (out.count == 0 || out.count > 16) return false;
    uint offset = values.count;
    for (uint i = 0; i < out.count; i++) {
        uint item = tree.list_item(items, i);
        if (item == 0 || tree.tags.data[item] == NodeTag.SPREAD) return false;
        if (out.object) {
            uint key = tree.lhs.data[item];
            if (tree.tags.data[item] != NodeTag.PROP_INIT || (tree.flags.data[item] & ast::PROP_COMPUTED) != 0
                || tree.tags.data[key] != NodeTag.STRING || tree.atoms.get(tree.lhs.data[key]) == "__proto__") return false;
            out.keys[i] = tree.lhs.data[key];
            out.expressions[i] = tree.rhs.data[item];
            NodeTag value_tag = tree.tags.data[out.expressions[i]];
            if (value_tag == NodeTag.FUNC_EXPR || value_tag == NodeTag.ARROW || value_tag == NodeTag.CLASS_EXPR) return false;
            for (uint j = 0; j < i; j++) { if (out.keys[i] == out.keys[j]) return false; }
        } else { out.expressions[i] = item; }
    }
    if (tree.tags.data[parameter] == NodeTag.IDENT && out.object) {
        for (uint i = 0; i < out.count; i++) {
            if (!inline_bind(values, tree.lhs.data[parameter], out.keys[i] + 1, (ushort)(offset + i))) return false;
        }
        return true;
    }
    if ((tree.tags.data[parameter] != NodeTag.OBJECT_PAT || !out.object)
        && (tree.tags.data[parameter] != NodeTag.ARRAY_PAT || !out.array)) return false;
    uint bindings = tree.lhs.data[parameter];
    for (uint i = 0; i < tree.list_len(bindings); i++) {
        uint bind = tree.list_item(bindings, i);
        uint selected = i;
        uint name;
        if (bind == 0) return false;
        if (out.object) {
            if (tree.tags.data[bind] != NodeTag.PAT_PROP || (tree.flags.data[bind] & ast::PROP_COMPUTED) != 0) return false;
            uint key = tree.lhs.data[tree.lhs.data[bind]];
            uint target = (tree.flags.data[bind] & ast::PROP_SHORTHAND_PAT) != 0 ? tree.lhs.data[bind] : tree.rhs.data[bind];
            if ((tree.flags.data[bind] & ast::PROP_SHORTHAND_PAT) != 0 && tree.rhs.data[bind] != 0) return false;
            if (tree.tags.data[target] != NodeTag.IDENT) return false;
            name = tree.lhs.data[target];
            selected = out.count;
            for (uint j = 0; j < out.count; j++) { if (out.keys[j] == key) selected = j; }
        } else {
            if (tree.tags.data[bind] != NodeTag.IDENT) return false;
            name = tree.lhs.data[bind];
        }
        if (selected >= out.count || !inline_bind(values, name, 0, (ushort)(offset + selected))) return false;
    }
    return true;
}

fn bool? CompilerContext.gen_inline_call(&self, uint node, Val* result) {
    if (self.disable_optimize || self.inline_values != null || self.in_with() || self.inner_func_count >= 255) return false;
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    if (idx.res.scopes.len > 128 || tree.tags.len > 8192) return false;
    uint callee = tree.lhs.data[node];
    bool immediate = tree.tags.data[callee] == NodeTag.ARROW || tree.tags.data[callee] == NodeTag.FUNC_EXPR;
    bool method = tree.tags.data[callee] == NodeTag.MEMBER;
    $if !$feat(PROTO_AST_METHODS): if (method) return false; $endif
    $if !$feat(PROTO_AST_INLINE): if (!method) return false; $endif
    if ((tree.flags.data[callee] & ast::FLAG_OPTIONAL) != 0 || (tree.flags.data[node] & ast::FLAG_OPTIONAL) != 0
        || (!immediate && !method && tree.tags.data[callee] != NodeTag.IDENT)) return false;
    uint function = immediate ? callee : 0;
    if (!immediate) {
        uint name = method ? tree.rhs.data[callee] : tree.lhs.data[callee];
        for (uint i = 1; i < idx.res.scopes.len; i++) {
            uint candidate = idx.res.scopes.data[i].node;
            if (idx.res.scopes.data[i].kind != ast::ScopeKind.FUNCTION) continue;
            if (!method && tree.tags.data[candidate] == NodeTag.FUNC_DECL && tree.lhs.data[candidate] != 0
                && tree.lhs.data[tree.lhs.data[candidate]] == name) { function = candidate; break; }
        }
        if (method) {
            for (uint i = 1; i < tree.tags.len; i++) {
                if (tree.tags.data[i] != NodeTag.CLASS_METHOD || (tree.flags.data[i] & (ast::MEMBER_GET | ast::MEMBER_SET | ast::PROP_COMPUTED)) != 0) continue;
                uint key = tree.lhs.data[i];
                if (tree.tags.data[key] == NodeTag.STRING && tree.lhs.data[key] == name) { function = tree.rhs.data[i]; break; }
            }
        }
    }
    if (function == 0) return false;
    uint rec = tree.rhs.data[function];
    if ((tree.field(rec, ast::FN_FLAGS) & (ast::FNF_ASYNC | ast::FNF_GENERATOR)) != 0) return false;
    uint params = tree.field(rec, ast::FN_PARAMS);
    uint args = tree.rhs.data[node];
    uint nargs = tree.list_len(args);
    if (nargs > 8 || nargs != tree.list_len(params)) return false;
    InlineValues values = { .method = method };
    InlineArg[8] arguments;
    uint staged = 0;
    for (uint i = 0; i < nargs; i++) {
        uint prior = values.count;
        if (!inline_argument(tree, tree.list_item(params, i), tree.list_item(args, i), &arguments[i], &values)) return false;
        for (uint j = prior; j < values.count; j++) values.values[j].reg = (ushort)(staged + values.values[j].reg - prior);
        staged += arguments[i].count;
        if (staged > 32 || (method && (arguments[i].object || arguments[i].array))) return false;
    }
    bool literal_argument = false;
    for (uint i = 0; i < nargs; i++) literal_argument |= arguments[i].object || arguments[i].array;
    if (!immediate && !method && !literal_argument) return false;
    uint body = tree.field(rec, ast::FN_BODY);
    uint expression = body;
    uint statements = 0;
    if ((tree.field(rec, ast::FN_FLAGS) & ast::FNF_EXPR_BODY) == 0) {
        statements = tree.lhs.data[body];
        uint count = tree.list_len(statements);
        if (count == 0 || count > 4 || (!method && count != 1)) return false;
        uint last = tree.list_item(statements, count - 1);
        if (tree.tags.data[last] != NodeTag.RETURN) return false;
        expression = tree.lhs.data[last];
        for (uint i = 0; i + 1 < count; i++) {
            uint statement = tree.list_item(statements, i);
            uint assign = tree.lhs.data[statement];
            uint lhs = tree.lhs.data[assign];
            TokenType op = (TokenType)(tree.flags.data[assign] & 0x7F);
            uint budget = 24;
            if (tree.tags.data[statement] != NodeTag.EXPR_STMT || tree.tags.data[assign] != NodeTag.ASSIGN
                || (op != TokenType.ASSIGN && op != TokenType.PLUS_ASSIGN)
                || tree.tags.data[lhs] != NodeTag.MEMBER || tree.tags.data[tree.lhs.data[lhs]] != NodeTag.THIS
                || !inline_expression(tree, tree.rhs.data[assign], &values, &budget)) return false;
        }
    }
    uint budget = 32;
    if (!inline_expression(tree, expression, &values, &budget) || self.next_reg + staged + nargs + 40 >= 256) return false;

    ushort base = self.alloc_persistent_reg();
    self.alloc_persistent_reg();
    for (uint i = 0; i < nargs; i++) self.alloc_persistent_reg();
    if (!immediate) {
        Phase phase = Phase.MEMBER;
        Val target = method ? self.gen_chain(callee, &phase)! : self.gen_expr(callee, 0)!;
        self.emit_abc(Opcode.LDREG, base, target.reg, 0);
        if (method) self.emit_abc(Opcode.LDREG, base + 1, self.call_prop_obj_reg, 0);
        self.call_prop_obj_reg = REG_NONE;
    }
    ushort first = self.next_reg;
    for (uint i = 0; i < staged; i++) self.alloc_persistent_reg();
    ushort floor = self.next_reg;
    uint position = 0;
    for (uint i = 0; i < nargs; i++) {
        for (uint j = 0; j < arguments[i].count; j++) {
            Val value = self.gen_expr(arguments[i].expressions[j], 0)!;
            arguments[i].registers[j] = (ushort)(first + position++);
            self.emit_abc(Opcode.LDREG, arguments[i].registers[j], value.reg, 0);
            self.free_regs_to(floor);
        }
        if (!arguments[i].object && !arguments[i].array) self.emit_abc(Opcode.LDREG, base + 2 + i, arguments[i].registers[0], 0);
    }
    for (uint i = 0; i < values.count; i++) values.values[i].reg += first;
    values.receiver = base + 1;
    ushort out = self.alloc_persistent_reg();
    uint slow = uint::max;
    if (!immediate) {
        CompilerContext guard_ctx;
        guard_ctx.init(self.lexer, self.heap);
        defer guard_ctx.cleanup();
        guard_ctx.inner_func_count = 1;
        guard_ctx.inner_funcs[0] = null;
        guard_ctx.num_args = (ushort)nargs;
        if (method) {
            for (uint i = 1; i < function; i++) {
                if (tree.main_tok.data[i] >= tree.main_tok.data[body] && tree.tags.data[i] == NodeTag.MEMBER
                    && tree.tags.data[tree.lhs.data[i]] == NodeTag.THIS) {
                    guard_ctx.add_string_constant(tree.atoms.get(tree.rhs.data[i]));
                }
            }
        }
        guard_ctx.emit_simple(Opcode.RETUNDEF);
        CompiledFunction* guard = guard_ctx.finish()!;
        bool linked = false;
        foreach (&link : idx.inline_links.data[:idx.inline_links.len]) {
            if (link.node != function) continue;
            guard.inner_funcs[0] = (CompiledFunction*)link.target;
            link.guards.push(guard);
            linked = true;
            break;
        }
        if (!linked) {
            ast::InlineLink link = { .node = function };
            link.guards.push(guard);
            idx.inline_links.push(link);
        }
        uint descriptor = self.add_inner_func(guard);
        self.emit_abc(Opcode.INLINE_GUARD, out, base, descriptor);
        slow = self.emit_cond_jump(Opcode.IF_FALSE, out);
    }
    uint[8] array_slow;
    uint array_count = 0;
    for (uint i = 0; i < nargs; i++) {
        if (arguments[i].array) {
            self.emit_simple(Opcode.ARRAY_PATTERN_GUARD);
            array_slow[array_count++] = self.emit_jump(Opcode.JUMP);
        }
    }
    self.inline_values = &values;
    defer self.inline_values = null;
    if (method && statements != 0) {
        for (uint i = 0; i + 1 < tree.list_len(statements); i++) self.free_val(self.gen_expr(tree.lhs.data[tree.list_item(statements, i)], 0)!);
    }
    Val value = self.gen_expr(expression, 0)!;
    self.emit_abc(Opcode.LDREG, out, value.reg, 0);
    self.inline_values = null;
    uint done = self.emit_jump(Opcode.JUMP);
    if (slow != uint::max) self.patch_jump(slow);
    for (uint i = 0; i < array_count; i++) self.patch_jump(array_slow[i]);
    self.free_regs_to(out + 1);
    if (immediate && array_count != 0) {
        Val target = self.gen_closure(function)!;
        self.emit_abc(Opcode.LDREG, base, target.reg, 0);
    }
    if (!immediate || array_count != 0) {
        for (uint i = 0; i < nargs; i++) {
            InlineArg* arg = &arguments[i];
            if (!arg.object && !arg.array) continue;
            ushort dest = (ushort)(base + 2 + i);
            if (arg.array) { self.emit_a_bc(Opcode.NEWARR, dest, arg.count); }
            else { self.emit_abc(Opcode.NEWOBJ, dest, 0, 0); }
            for (uint j = 0; j < arg.count; j++) {
                if (arg.array) { self.emit_abc(Opcode.INITELEM, dest, j, arg.registers[j]); }
                else {
                    ushort key = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, key, self.add_string_constant(tree.atoms.get(arg.keys[j])));
                    self.emit_abc(Opcode.INITPROP, dest, key, arg.registers[j]);
                    self.free_reg(key);
                }
            }
        }
        self.emit_abc(method ? Opcode.CALL : Opcode.CALL_UNDEF_THIS, base, base, nargs);
        self.emit_abc(Opcode.LDREG, out, base, 0);
    }
    self.patch_jump(done);
    self.free_regs_to(out + 1);
    self.call_prop_obj_reg = REG_NONE;
    *result = (Val){ out, false, 0 };
    return true;
}
