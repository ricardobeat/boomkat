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
// an operator must not use as its destination. `lreg` is the home register of the last local
// variable read while compiling the expression; the fused compiler's `last_local_var_reg`.
struct Val {
    ushort reg;
    bool local;
    ushort lreg;
}

// Release `v` unless it is a live local's home register.
fn void CompilerContext.free_val(&self, Val v) {
    if (v.local && v.lreg == v.reg) return;
    self.free_reg(v.reg);
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
    if (!has_return) {
        self.gen_line(tree.field(rec, ast::FN_SRC_END) - 1);
        self.emit_simple(Opcode.RETUNDEF);
    }
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
        case IF:
            self.gen_if(n)!;
        case WHILE:
            self.gen_while(n)!;
        case DO_WHILE:
            self.gen_do_while(n)!;
        case FOR:
            self.gen_for(n)!;
        case BREAK:
            self.gen_break()!;
        case CONTINUE:
            self.gen_continue()!;
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

// ---- control flow ----

fn void? CompilerContext.gen_if(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    uint cons = tree.field(rec, 0);
    uint alt = tree.field(rec, 1);
    Val cond = self.gen_expr(tree.lhs.data[n], false)!;
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond.reg);
    self.free_val(cond);
    self.gen_stmt(cons)!;
    if (alt != 0) {
        self.gen_line(tree.field(rec, 2));
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);
        self.gen_stmt(alt)!;
        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

// A loop condition of the form `<identifier> <relop> <number literal>`, none of it parenthesised.
// Its right operand is loaded once into a pinned register ahead of the loop.
fn bool CompilerContext.gen_simple_cond(&self, uint test, Opcode* op, double* rhs) {
    ast::Ast* tree = &ast::index_state.tree;
    if (test == 0 || tree.tags.data[test] != NodeTag.BINARY || (tree.flags.data[test] & ast::FLAG_PAREN) != 0) return false;
    uint l = tree.lhs.data[test];
    uint r = tree.rhs.data[test];
    if (tree.tags.data[l] != NodeTag.IDENT || (tree.flags.data[l] & ast::FLAG_PAREN) != 0) return false;
    if (tree.tags.data[r] != NodeTag.NUMBER || (tree.flags.data[r] & ast::FLAG_PAREN) != 0) return false;
    switch ((TokenType)tree.flags.data[test]) {
        case LT: *op = Opcode.LT;
        case LE: *op = Opcode.LE;
        case GT: *op = Opcode.GT;
        case GE: *op = Opcode.GE;
        default: return false;
    }
    ulong bits = ((ulong)tree.rhs.data[r] << 32) | (ulong)tree.lhs.data[r];
    *rhs = bitcast(bits, double);
    return true;
}

fn ushort CompilerContext.gen_pinned_number(&self, double val) {
    ushort reg = self.alloc_reg();
    int int_val = (int)val;
    if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
        self.emit_a_sbx(Opcode.LDINT, (uint)reg, int_val);
    } else {
        self.emit_a_bc(Opcode.LDCONST, (uint)reg, self.add_number_constant(val));
    }
    return reg;
}

// The loop's test, run at the bottom: jump back to `body_label` while it holds.
fn void? CompilerContext.gen_loop_test(&self, uint test, uint body_label, bool simple, Opcode op, ushort pinned) {
    ast::Ast* tree = &ast::index_state.tree;
    if (simple) {
        uint l = tree.lhs.data[test];
        self.gen_line(tree.main_tok.data[l]);
        char[] name = self.gen_name(tree.lhs.data[l]);
        ushort lhs_reg = self.alloc_reg();
        if (try reg = self.resolve_var(name)) {
            if (reg != lhs_reg) self.emit_abc(Opcode.LDREG, (uint)lhs_reg, (uint)reg, 0);
        } else {
            self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, self.add_string_constant(name));
        }
        ushort cmp_res = self.alloc_reg();
        self.emit_abc(op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned);
        self.free_reg(lhs_reg);
        self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cmp_res, body_label);
        self.free_reg(cmp_res);
        self.free_reg(pinned);
    } else {
        Val cond = self.gen_expr(test, false)!;
        self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cond.reg, body_label);
        self.free_val(cond);
    }
}

// Loops run rotated: a jump to the test, the body, then the test with a back edge.
fn void? CompilerContext.gen_while(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint test = tree.lhs.data[n];
    bool const_true = tree.tags.data[test] == NodeTag.TRUE_LIT && (tree.flags.data[test] & ast::FLAG_PAREN) == 0;
    Opcode op;
    double rhs;
    bool simple = !const_true && self.gen_simple_cond(test, &op, &rhs);
    ushort pinned = simple ? self.gen_pinned_number(rhs) : 0;
    uint cond_jump = 0;
    if (!const_true) cond_jump = self.emit_jump(Opcode.JUMP);
    uint body_label = self.code_count;
    self.push_loop(body_label, true);
    self.gen_stmt(tree.rhs.data[n])!;
    self.innermost_loop().continue_target = self.code_count;
    if (const_true) {
        self.emit(bytecode::make_sabc(Opcode.JUMP, (int)body_label - (int)self.code_count - 1));
    } else {
        self.patch_jump(cond_jump);
        self.gen_loop_test(test, body_label, simple, op, pinned)!;
    }
    self.pop_loop();
}

fn void? CompilerContext.gen_do_while(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);
    self.gen_stmt(tree.lhs.data[n])!;
    self.innermost_loop().continue_target = self.code_count;
    Val cond = self.gen_expr(tree.rhs.data[n], false)!;
    self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cond.reg, loop_start);
    self.free_val(cond);
    self.pop_loop();
}

// `for (var ...; test; update)`: a `var` head whose first declarator may live in a register that
// is written back to the environment around the loop.
fn void? CompilerContext.gen_for(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.lhs.data[n];
    uint init = tree.field(rec, 0);
    uint test = tree.field(rec, 1);
    uint update = tree.field(rec, 2);
    uint body = tree.field(rec, 3);
    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;
    bool has_for_var = false;
    ushort for_var_reg = 0;
    uint for_var_name_idx = 0;

    if (init != 0 && tree.tags.data[init] == NodeTag.VAR_DECL) {
        uint decls = tree.lhs.data[init];
        for (uint i = 0; i < tree.list_len(decls); i++) {
            uint d = tree.list_item(decls, i);
            char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[d]]);
            uint value = tree.rhs.data[d];
            ushort reg;
            bool env_resident = false;
            if (i == 0) {
                if (try existing = self.find_local_reg(name)) {
                    reg = existing;
                    env_resident = self.is_existing_local_env_resident(name);
                } else {
                    reg = self.declare_var(name, VAR);
                }
                has_for_var = !self.is_global && !self.is_captured_name(name);
                if (has_for_var) {
                    if (catch self.resolve_var(name)) has_for_var = false;
                }
                for_var_reg = reg;
                for_var_name_idx = self.add_string_constant(name);
            } else if (try existing = self.resolve_var(name)) {
                reg = existing;
            } else {
                reg = self.declare_var(name, VAR);
            }
            if (value != 0) {
                Val v = self.gen_expr(value, false)!;
                if (v.reg != reg) self.emit_abc(Opcode.LDREG, (uint)reg, (uint)v.reg, 0);
                self.free_reg(v.reg);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }
            self.emit_var_store(reg, i == 0 ? for_var_name_idx : self.add_string_constant(name), false, false, env_resident);
        }
    } else if (init != 0) {
        Val v = self.gen_expr(init, false)!;
        self.free_reg(v.reg);
        if (self.next_reg < saved_reg) self.next_reg = saved_reg;
    }

    // Temporaries of the test and update sit above every local the head declared.
    ushort cond_floor = self.next_reg;
    if (cond_floor < saved_reg) cond_floor = saved_reg;

    Opcode op;
    double rhs;
    bool simple = self.gen_simple_cond(test, &op, &rhs);
    ushort pinned = simple ? self.gen_pinned_number(rhs) : 0;
    uint cond_jump = 0;
    if (test != 0) cond_jump = self.emit_jump(Opcode.JUMP);
    uint body_label = self.code_count;
    self.push_loop(body_label, true);
    self.gen_stmt(body)!;

    self.innermost_loop().continue_target = self.code_count;
    if (update != 0) {
        if (self.next_reg < cond_floor) self.next_reg = cond_floor;
        Val v = self.gen_expr(update, true)!;
        if (!(v.local && v.lreg == v.reg)) self.free_reg(v.reg);
    }
    bool iter_sync = has_for_var && (self.has_closures || self.has_direct_eval);
    if (iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }
    if (test != 0) {
        self.patch_jump(cond_jump);
        if (!simple && self.next_reg < cond_floor) self.next_reg = cond_floor;
        self.gen_loop_test(test, body_label, simple, op, pinned)!;
    } else {
        self.emit(bytecode::make_sabc(Opcode.JUMP, (int)body_label - (int)self.code_count - 1));
    }
    self.pop_loop();
    if (has_for_var && !iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

fn void? CompilerContext.gen_break(&self) {
    if (self.loop_depth() == 0) return self.fail("'break' is only valid inside a loop or switch")~;
    int loop_idx = (int)self.loop_depth() - 1;
    int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
    while (self.cur_lex_depth > target_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    while (self.cur_with_depth > self.loop_stack[loop_idx].saved_with_depth) {
        self.emit_abc(Opcode.WITH_END, 0, 0, 0);
        self.cur_with_depth--;
    }
    if (self.loop_stack[loop_idx].iter_close_reg >= 0) self.emit_unwind_iter_close((uint)loop_idx);
    uint jump_addr = self.emit_jump(self.loop_jump_op((uint)loop_idx, Opcode.BREAK));
    self.add_break_patch(jump_addr);
}

// Jumps to the continue target of the innermost loop, skipping switches, which only take `break`.
fn void? CompilerContext.gen_continue(&self) {
    int loop_idx = (int)self.loop_depth() - 1;
    while (loop_idx >= 0 && !self.loop_stack[loop_idx].is_loop) loop_idx--;
    if (loop_idx < 0) return COMPILE_ERROR~;
    int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
    while (self.cur_lex_depth > target_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    uint jump_addr = self.emit_jump(self.loop_jump_op((uint)loop_idx, Opcode.CONTINUE));
    self.loop_stack[loop_idx].continue_patch_head =
        self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
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
            return { reg, false, 0 };
        case STRING:
            uint idx = self.add_string_constant(tree.atoms.get(tree.lhs.data[n]));
            ushort reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)reg, idx);
            return { reg, false, 0 };
        case THIS:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)reg, 0, 0);
            return { reg, false, 0 };
        case NULL_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDNULL, (uint)reg, 0, 0);
            return { reg, false, 0 };
        case TRUE_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTRUE, (uint)reg, 0, 0);
            return { reg, false, 0 };
        case FALSE_LIT:
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.LDFALSE, (uint)reg, 0, 0);
            return { reg, false, 0 };
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
    if (try local = self.resolve_var(name)) return { local, true, local };
    uint name_idx = self.add_string_constant(name);
    ushort reg = self.alloc_reg();
    self.emit_ident_read((uint)reg, name_idx)!;
    return { reg, false, 0 };
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
    return { dest, right.local, right.lreg };
}
