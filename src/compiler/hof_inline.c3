module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;

// Inlined Array.prototype callbacks: `recv.m(x => ...)` for forEach, map,
// filter, some, every, find and findIndex, and `recv.reduce((a, x) => ...,
// init)`, compile to a loop running the arrow's body in the caller's frame. HOF_GUARD checks at run time that the method is the
// intrinsic and the receiver an Array; anything else takes the ordinary call.
//
// The arrow has simple parameters and an expression body (forEach also takes
// a block body without `return`), and contains no function, class, `eval` or
// `var`, so its parameters are never captured and evaluating its body inline
// is the same as calling it. An arrow's `this`, `arguments` and `new.target`
// are the caller's already.

// Ordinals match the VM's HOF_BUILTINS.
enum HofKind : char {
    FOR_EACH,
    REDUCE,
    MAP,
    FILTER,
    SOME,
    EVERY,
    FIND,
    FIND_INDEX,
}

faultdef NOT_HOF_CALL;

fn bool CompilerContext.hof_arrow_inlinable(&self, uint first, uint arrow, uint max_params, bool block_ok) {
    ast::Ast* tree = &ast::index_state.tree;
    if (tree.tags.data[arrow] != NodeTag.ARROW) return false;
    uint rec = tree.rhs.data[arrow];
    uint fnf = tree.field(rec, ast::FN_FLAGS);
    if ((fnf & ast::FNF_ASYNC) != 0 || (fnf & ast::FNF_SIMPLE_PARAMS) == 0) return false;
    if (tree.list_len(tree.field(rec, ast::FN_PARAMS)) > max_params) return false;
    if ((fnf & ast::FNF_EXPR_BODY) == 0 && !block_ok) return false;
    for (uint i = first; i < arrow; i++) {
        switch (tree.tags.data[i]) {
            case FUNC_EXPR: case ARROW: case CLASS_EXPR: case CLASS_DECL: case FUNC_DECL:
            case RETURN: case LABELED: case TRY: case WITH:
                return false;
            case VAR_DECL:
                if ((tree.flags.data[i] & ast::VAR_KIND_MASK) == ast::VAR_KIND_VAR) return false;
            case IDENT:
                if (tree.atoms.get(tree.lhs.data[i]) == "eval") return false;
            default:
                break;
        }
    }
    return true;
}

fn Val? CompilerContext.gen_hof_call(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint callee = tree.lhs.data[n];
    uint args = tree.rhs.data[n];
    if (g_disable_optimize || self.is_global || self.in_with() || self.capture_all
        || (tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0
        || tree.tags.data[callee] != NodeTag.MEMBER || (tree.flags.data[callee] & ast::FLAG_OPTIONAL) != 0
        || tree.list_len(args) == 0) return NOT_HOF_CALL~;
    char[] method = tree.atoms.get(tree.rhs.data[callee]);
    HofKind kind;
    uint nargs;
    switch (method) {
        case "forEach": kind = FOR_EACH; nargs = 1;
        case "reduce": kind = REDUCE; nargs = 2;
        case "map": kind = MAP; nargs = 1;
        case "filter": kind = FILTER; nargs = 1;
        case "some": kind = SOME; nargs = 1;
        case "every": kind = EVERY; nargs = 1;
        case "find": kind = FIND; nargs = 1;
        case "findIndex": kind = FIND_INDEX; nargs = 1;
        default: return NOT_HOF_CALL~;
    }
    if (tree.list_len(args) != nargs) return NOT_HOF_CALL~;
    uint arrow = tree.list_item(args, 0);
    if (nargs > 1 && tree.tags.data[tree.list_item(args, 1)] == NodeTag.SPREAD) return NOT_HOF_CALL~;
    uint max_params = kind == REDUCE ? 4 : 3;
    if (!self.hof_arrow_inlinable(callee + 1, arrow, max_params, kind == FOR_EACH)) return NOT_HOF_CALL~;

    self.gen_line_main(n);
    ushort f = self.alloc_reg();
    ushort recv = self.alloc_reg();
    Val obj = self.gen_expr(tree.lhs.data[callee], 0)!;
    self.emit_abc(Opcode.LDREG, (uint)recv, (uint)obj.reg, 0);
    self.free_val(obj);
    self.emit_abc(Opcode.GETPROPC, (uint)f, (uint)recv, self.add_string_constant(method));
    ushort len = self.alloc_reg();
    self.emit_abc(Opcode.HOF_GUARD, (uint)len, (uint)f, (uint)kind.ordinal);
    uint slow = self.emit_jump(Opcode.JUMP);

    // Fast path. f holds the result.
    ushort count = 0;
    switch (kind) {
        case REDUCE:
            Val init = self.gen_expr(tree.list_item(args, 1), 0)!;
            self.emit_abc(Opcode.LDREG, (uint)f, (uint)init.reg, 0);
            self.free_val(init);
        case MAP:
            self.emit_abc(Opcode.HOF_NEWARR, (uint)f, (uint)len, 1);
        case FILTER:
            self.emit_abc(Opcode.HOF_NEWARR, (uint)f, (uint)len, 0);
            count = self.alloc_reg();
            self.emit_a_sbx(Opcode.LDINT, (uint)count, 0);
        case SOME:
            self.emit_abc(Opcode.LDFALSE, (uint)f, 0, 0);
        case EVERY:
            self.emit_abc(Opcode.LDTRUE, (uint)f, 0, 0);
        case FIND_INDEX:
            self.emit_a_sbx(Opcode.LDINT, (uint)f, -1);
        default:
            self.emit_abc(Opcode.LDUNDEF, (uint)f, 0, 0);
    }
    ushort idx = self.alloc_reg();
    ushort elem = self.alloc_reg();
    self.emit_a_sbx(Opcode.LDINT, (uint)idx, 0);
    uint top = self.code_count;
    ushort cond = self.alloc_reg();
    self.emit_abc(Opcode.LT, (uint)cond, (uint)idx, (uint)len);
    uint exit = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond);
    self.free_reg(cond);
    uint skip = NO_PATCH;
    if (kind == FIND || kind == FIND_INDEX) {
        self.emit_abc(Opcode.HOF_GET, (uint)elem, (uint)recv, (uint)idx);
    } else {
        self.emit_abc(Opcode.HOF_ELEM, (uint)elem, (uint)recv, (uint)idx);
        skip = self.emit_jump(Opcode.JUMP);
    }

    uint rec = tree.rhs.data[arrow];
    uint params = tree.field(rec, ast::FN_PARAMS);
    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;
    self.push_scope_marker();
    // Arguments in call order: (elem, idx, recv), with reduce's accumulator first.
    ushort[4] sources;
    uint nsrc = 0;
    if (kind == REDUCE) sources[nsrc++] = f;
    sources[nsrc++] = elem;
    sources[nsrc++] = idx;
    sources[nsrc++] = recv;
    for (uint i = 0; i < tree.list_len(params); i++) {
        char[] pname = self.gen_name(tree.lhs.data[tree.list_item(params, i)]);
        ushort preg = self.declare_var(pname, LET);
        self.emit_abc(Opcode.LDREG, (uint)preg, (uint)sources[i], 0);
        self.emit_var_store(preg, self.add_string_constant(pname), true, false);
    }
    uint body = tree.field(rec, ast::FN_BODY);
    uint found = NO_PATCH;
    if ((tree.field(rec, ast::FN_FLAGS) & ast::FNF_EXPR_BODY) == 0) {
        self.gen_block(body, false)!;
    } else if (kind == FOR_EACH) {
        self.free_val(self.gen_expr(body, CTX_STMT)!);
    } else {
        Val v = self.gen_expr(body, 0)!;
        switch (kind) {
            case REDUCE:
                self.emit_abc(Opcode.LDREG, (uint)f, (uint)v.reg, 0);
            case MAP:
                self.emit_abc(Opcode.HOF_PUT, (uint)f, (uint)idx, (uint)v.reg);
            case FILTER:
                uint no = self.emit_cond_jump(Opcode.IF_FALSE, (uint)v.reg);
                self.emit_abc(Opcode.HOF_PUT, (uint)f, (uint)count, (uint)elem);
                self.emit_abc(Opcode.ADDI, (uint)count, (uint)count, 1);
                self.patch_jump(no);
            case EVERY:
                uint yes = self.emit_cond_jump(Opcode.IF_TRUE, (uint)v.reg);
                self.emit_abc(Opcode.LDFALSE, (uint)f, 0, 0);
                found = self.emit_jump(Opcode.JUMP);
                self.patch_jump(yes);
            default:
                uint no = self.emit_cond_jump(Opcode.IF_FALSE, (uint)v.reg);
                if (kind == SOME) self.emit_abc(Opcode.LDTRUE, (uint)f, 0, 0);
                if (kind == FIND) self.emit_abc(Opcode.LDREG, (uint)f, (uint)elem, 0);
                if (kind == FIND_INDEX) self.emit_abc(Opcode.LDREG, (uint)f, (uint)idx, 0);
                found = self.emit_jump(Opcode.JUMP);
                self.patch_jump(no);
        }
        self.free_val(v);
    }
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);

    if (skip != NO_PATCH) self.patch_jump(skip);
    self.emit_abc(Opcode.ADDI, (uint)idx, (uint)idx, 1);
    uint back = self.emit_jump(Opcode.JUMP);
    self.patch_jump_to(back, top);
    self.patch_jump(exit);
    if (found != NO_PATCH) self.patch_jump(found);
    uint done = self.emit_jump(Opcode.JUMP);

    // Ordinary call with the receiver and method already evaluated.
    self.patch_jump(slow);
    self.free_regs_to(recv + 1);
    for (uint i = 0; i < nargs; i++) {
        ushort slot = self.alloc_reg();
        Val v = self.gen_expr(tree.list_item(args, i), 0)!;
        if (v.reg != slot) self.emit_abc(Opcode.LDREG, (uint)slot, (uint)v.reg, 0);
        self.free_regs_to(slot + 1);
    }
    self.gen_line_end(n);
    self.emit_abc(Opcode.CALL, (uint)f, (uint)f, nargs);
    self.patch_jump(done);
    self.free_regs_to(f + 1);
    return { f, false, 0 };
}
