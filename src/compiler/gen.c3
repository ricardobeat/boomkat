module boomkat::compiler;

import boomkat::types;
import boomkat::ast;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::heap;
import std::collections::list;
import std::io;

// ============================================================================
// Code generation from the flat AST (plan 101, stage 7)
//
// A function the AST index marks as supported (ast/support.c3) is generated from its tree in place
// of the fused parse-and-emit path. The generator drives the same CompilerContext machinery:
// registers, scope stack, constants, `finish()` and its post-passes. What it does not have is any
// token reading.
// ============================================================================

// An expression's result register. `local` marks the home register of a live local variable, which
// an operator must not use as its destination.
struct Val {
    ushort reg;
    bool local;
}

bool gen_enabled = true;   // generate supported functions from the AST
bool gen_trace;            // report each generated function on stderr

fn char[] CompilerContext.gen_name(&self, uint atom) {
    char[] raw = ast::index_state.tree.atoms.get(atom);
    return ((Heap*)self.heap).str_intern(raw).get_data();
}

// Set the line the next emitted instruction is attributed to.
fn void CompilerContext.gen_line(&self, uint tok) {
    self.lexer.current.line = ast::index_state.tree.position(tok).line;
}

// ---- functions ----

// The scope of the function whose parameter list the lexer is about to read, when the generator
// can compile it; 0 otherwise.
fn uint CompilerContext.gen_function_scope(&self) {
    ast::AstIndex* idx = ast::index_state;
    if (!gen_enabled || idx == null || !idx.use) return 0;
    if (self.lexer.ts_mode || self.pushback_count != 0 || self.lexer.has_pushed_back) return 0;
    uint at = self.lexer.has_lookahead
        ? self.lexer.lookahead.pos
        : idx.skip_trivia_forward(self.lexer.pos);
    if (at >= (uint)self.lexer.source.len || self.lexer.source[at] != '(') return 0;
    uint scope = idx.function_at_paren(at);
    if (scope == 0) return 0;
    if (!idx.gen_supported(scope)) {
        if (gen_trace) io::eprintfn("AST-GEN-SKIP %s", (String)idx.reject_why);
        return 0;
    }
    return scope;
}

// Leave the lexer as the fused path does after a function body: `}` consumed, and a `/` after it
// division when the function is an operand.
fn void? CompilerContext.gen_resume_after(&self, uint end, bool is_expr) {
    ast::SourcePos at = ast::index_state.tree.position(end - 1);
    self.pushback_count = 0;
    self.seek_lexer_to({ .pos = end - 1, .line = at.line, .col = at.col });
    self.expect(TokenType.RBRACE)!;
    if (!is_expr) self.lexer.note_block_close();
}

// Generate the function of `scope` into this (fresh) context.
fn void? CompilerContext.gen_function(&self, uint scope) {
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    ast::Scope* sc = &idx.res.scopes.data[scope];
    uint rec = tree.rhs.data[sc.node];
    uint fnf = tree.field(rec, ast::FN_FLAGS);

    self.is_strict = (fnf & ast::FNF_STRICT) != 0;
    self.lexer.set_strict(self.is_strict);
    if ((fnf & ast::FNF_USE_STRICT) != 0) self.saw_use_strict = true;

    // Parameters: plain identifiers, each a DECLVAR in the function's variable environment.
    uint params = tree.field(rec, ast::FN_PARAMS);
    ushort arg_count = 0;
    List{uint} param_names;
    param_names.init(mem, initial_capacity: MAX_PARAMS);
    defer param_names.free();
    uint nparams = tree.list_len(params);
    for (uint i = 0; i < nparams; i++) {
        uint p = tree.list_item(params, i);
        char[] name = self.gen_name(tree.lhs.data[p]);
        ushort reg = self.declare_var(name, VAR, true);
        uint name_idx = self.add_string_constant(name);
        arg_count++;
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
        param_name_set(&param_names, arg_count - 1, name_idx);
    }
    self.num_args = arg_count;
    self.formal_count = arg_count;
    self.emit_param_prologue(arg_count, 0xFFFF, param_name_view(&param_names, arg_count))!;

    self.index_captures_of(scope);
    self.apply_capture_set();
    self.reserve_arguments_register();

    self.hoist_decls_in(scope, false, false)!;
    self.reserved_regs = self.next_reg;

    self.gen_function_body(tree.field(rec, ast::FN_BODY))!;
    if (gen_trace) io::eprintfn("AST-GEN function at %d", tree.position(tree.field(rec, ast::FN_SRC_START)).line);

    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        has_return = last_op == Opcode.RET || last_op == Opcode.RETUNDEF
            || last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN;
    }
    if (has_return && self.branch_targets_fall_off_end()) has_return = false;
    if (!has_return) self.emit_simple(Opcode.RETUNDEF);
}

fn void? CompilerContext.gen_function_body(&self, uint body) {
    self.gen_block(body, true)!;
}

// A block's statements inside their own scope: the scope marker, and the registers its
// declarations took, are released at the end.
fn void? CompilerContext.gen_block(&self, uint n, bool is_body) {
    ast::Ast* tree = &ast::index_state.tree;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;
    self.push_scope_marker(is_body);
    uint stmts = tree.lhs.data[n];
    for (uint i = 0; i < tree.list_len(stmts); i++) self.gen_stmt(tree.list_item(stmts, i))!;
    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

// ---- statements ----

fn void? CompilerContext.gen_stmt(&self, uint n) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    ushort stmt_base = self.next_reg;
    self.gen_line(tree.main_tok.data[n]);
    switch (tree.tags.data[n]) {
        case EMPTY_STMT:
            break;
        case DIRECTIVE:
            break;
        case BLOCK:
            self.gen_block(n, false)!;
        case EXPR_STMT:
            Val v = self.gen_expr(tree.lhs.data[n], true)!;
            if (v.reg + 1 != self.next_reg || !self.is_local_var_reg(v.reg)) self.free_reg(v.reg);
        case RETURN:
            uint arg = tree.lhs.data[n];
            if (arg == 0) {
                self.emit_return_iter_closes();
                self.emit_simple(Opcode.RETUNDEF);
            } else {
                Val v = self.gen_expr(arg, false)!;
                self.emit_return_iter_closes();
                self.emit_abc(Opcode.RET, (uint)v.reg, 0, 0);
            }
        case VAR_DECL:
            self.gen_var_decl(n)!;
        default:
            return self.fail("unsupported statement in AST generation")~;
    }
    self.reclaim_stmt_regs(stmt_base);
}

fn void? CompilerContext.gen_var_decl(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    self.has_local_bindings = true;
    uint decls = tree.lhs.data[n];
    for (uint i = 0; i < tree.list_len(decls); i++) {
        uint d = tree.list_item(decls, i);
        char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[d]]);
        uint init = tree.rhs.data[d];
        ushort reg;
        bool already_declared = false;
        if (try existing = self.find_local_reg(name)) {
            reg = existing;
            already_declared = true;
        } else {
            reg = self.declare_var(name, VAR);
        }
        if (init != 0) {
            NameEvalFrame nef = self.save_name_eval();
            defer self.restore_name_eval(nef);
            self.has_inferred_name = true;
            self.inferred_name = name;
            Val v = self.gen_expr(init, false)!;
            if (v.reg != reg) self.emit_abc(Opcode.LDREG, (uint)reg, (uint)v.reg, 0);
            self.free_reg(v.reg);
        } else if (!already_declared) {
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
        }
        if (!already_declared || init != 0) {
            uint name_idx = self.add_string_constant(name);
            if (init == 0) {
                self.emit_a_bc(Opcode.DECLVAR_HOIST, (uint)reg, name_idx);
            } else {
                bool walk_chain = already_declared && self.names_catch_param(name);
                self.emit_var_store(reg, name_idx, false, false, walk_chain);
            }
        }
    }
}

// ---- expressions ----

// Compile expression `n`. `discard` says the value is unused, which lets an assignment skip its
// result-preserving move.
fn Val? CompilerContext.gen_expr(&self, uint n, bool discard) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    switch (tree.tags.data[n]) {
        case NUMBER:
            ulong bits = ((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n];
            double val = bitcast(bits, double);
            ushort reg = self.alloc_reg();
            int int_val = (int)val;
            if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
                self.emit_a_sbx(Opcode.LDINT, (uint)reg, int_val);
            } else {
                self.emit_a_bc(Opcode.LDCONST, (uint)reg, self.add_number_constant(val));
            }
            return { reg, false };
        case STRING:
            uint idx = self.add_string_constant(tree.atoms.get(tree.lhs.data[n]));
            ushort reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)reg, idx);
            return { reg, false };
        case THIS:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)reg, 0, 0);
            return { reg, false };
        case NULL_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDNULL, (uint)reg, 0, 0);
            return { reg, false };
        case TRUE_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTRUE, (uint)reg, 0, 0);
            return { reg, false };
        case FALSE_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDFALSE, (uint)reg, 0, 0);
            return { reg, false };
        case IDENT:
            return self.gen_ident(n);
        case BINARY:
            return self.gen_binary(n);
        default:
            return self.fail("unsupported expression in AST generation")~;
    }
}

fn Val? CompilerContext.gen_ident(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    char[] name = self.gen_name(tree.lhs.data[n]);
    if (try local = self.resolve_var(name)) return { local, true };
    uint name_idx = self.add_string_constant(name);
    ushort reg = self.alloc_reg();
    self.emit_ident_read((uint)reg, name_idx)!;
    return { reg, false };
}

fn Val? CompilerContext.gen_binary(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    Opcode op = token_to_binary_opcode((TokenType)(tree.flags.data[n] & 0x7F));
    Val left = self.gen_expr(tree.lhs.data[n], false)!;
    Val right = self.gen_expr(tree.rhs.data[n], false)!;
    ushort dest = left.reg;
    if (left.local) {
        dest = self.alloc_reg();
        if (cmp_branch_fused_op(op, true) != Opcode.NOP) {
            self.emit_abc(Opcode.LDREG, (uint)dest, (uint)left.reg, 0);
            left.reg = dest;
        }
    }
    self.emit_abc(op, (uint)dest, (uint)left.reg, (uint)right.reg);
    self.free_reg(right.reg);
    return { dest, right.local };
}
