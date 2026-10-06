module boomkat::compiler;

import boomkat::types;
import boomkat::ast;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::collections::list;
import std::io;
import std::core::string;
import std::math;

// Generation drives the shared register, scope, constant and bytecode machinery.
// `local` protects a binding's home register; `lreg` carries its reference through
// operators that return a temporary.
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

bool gen_trace;            // report each generated function on stderr

fn char[] CompilerContext.gen_name(&self, uint atom) {
    char[] raw = ast::index_state.tree.atoms.get(atom);
    return ((Heap*)self.heap).str_intern(raw).get_data();
}

// Set the line the next emitted instruction is attributed to.
fn void CompilerContext.gen_line(&self, uint tok) {
    self.lexer.current.line = ast::index_state.tree.position(tok).line;
}

// Attribute following instructions to the node's closing token.
fn void CompilerContext.gen_line_end(&self, uint n) {
    self.gen_line(ast::index_state.tree.end_tok.data[n]);
}

// Attributes the instructions that follow to the node's own token.
fn void CompilerContext.gen_line_main(&self, uint n) {
    self.gen_line(ast::index_state.tree.main_tok.data[n]);
}

// ---- functions ----

// Generate the function of `scope` into this (fresh) context.
fn void? CompilerContext.gen_function(&self, uint scope) {
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    ast::Scope* sc = &idx.res.scopes.data[scope];
    uint rec = tree.rhs.data[sc.node];
    uint fnf = tree.field(rec, ast::FN_FLAGS);

    self.scan_has_with = (sc.flags & ast::SCOPE_HAS_WITH) != 0;
    self.capture_all = self.outer_with || self.scan_has_with || (sc.flags & ast::SCOPE_CAPTURE_ALL) != 0;

    self.is_strict = (fnf & ast::FNF_STRICT) != 0;
    self.lexer.set_strict(self.is_strict);
    if ((fnf & ast::FNF_USE_STRICT) != 0) self.saw_use_strict = true;
    bool arrow = self.is_arrow;
    if (arrow) {
        self.gen_line(tree.field(rec, ast::FN_HEADER_END));
        self.emit_simple(Opcode.PUSH_VAR);
    }

    // Parameters: plain identifiers, each a DECLVAR in the function's variable environment.
    uint params = tree.field(rec, ast::FN_PARAMS);
    ushort arg_count = 0;
    ushort first_default = 0xFFFF;
    ushort formals = 0;
    List{uint} param_names;
    param_names.init(mem, initial_capacity: MAX_PARAMS);
    defer param_names.free();
    DestructBinds param_binds = { .allocator = mem };
    defer free_destruct_binds(&param_binds);
    uint nparams = tree.list_len(params);
    bool inline_defaults = !self.disable_optimize && !self.capture_all
        && !self.is_arrow && !self.is_generator && !self.is_async
        && !self.in_class_body && !self.has_super_binding;
    for (uint i = 0; inline_defaults && i < nparams; i++) {
        uint p = tree.list_item(params, i);
        if (tree.tags.data[p] == NodeTag.ASSIGN_PAT) p = tree.lhs.data[p];
        inline_defaults = tree.tags.data[p] == NodeTag.IDENT;
    }
    self.in_formal_params = true;
    for (uint i = 0; i < nparams; i++) {
        uint p = tree.list_item(params, i);
        bool rest = tree.tags.data[p] == NodeTag.REST;
        bool has_default = tree.tags.data[p] == NodeTag.ASSIGN_PAT;
        uint id = rest || has_default ? tree.lhs.data[p] : p;
        if (tree.tags.data[id] == NodeTag.ARRAY_PAT || tree.tags.data[id] == NodeTag.OBJECT_PAT) {
            self.has_destructured_param = true;
            self.alloc_reg();
            self.gen_collect_pattern(id, &param_binds, arg_count)!;
            self.gen_line_end(id);
            if (has_default) {
                uint thunk = self.add_inner_func(self.compile_default_expr({}, tree.rhs.data[p])!);
                self.destruct_defaults.push({ .arg_slot = arg_count, .default_func_idx = thunk });
                if (first_default == 0xFFFF) first_default = arg_count;
            }
            arg_count++;
            if (rest) {
                self.has_rest = true;
                self.rest_formal_count = arg_count - 1;
            } else if (first_default == 0xFFFF) {
                formals++;
            }
            continue;
        }
        self.gen_line_main(id);
        char[] name = self.gen_name(tree.lhs.data[id]);
        ushort reg = self.declare_var(name, VAR, true);
        uint name_idx = self.add_string_constant(name);
        arg_count++;
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
        param_name_set(&param_names, arg_count - 1, name_idx);
        if (rest) {
            self.has_rest = true;
            self.rest_formal_count = arg_count - 1;
        } else {
            if (has_default) {
                self.gen_line_main(p);
                uint expr = tree.rhs.data[p];
                uint budget = 32;
                if (inline_defaults && inline_param_expr(tree, expr, params, i, &budget)) {
                    self.defaults.push({ .param_reg = reg, .param_name_idx = name_idx, .ast_expr = expr });
                } else {
                    self.push_param_default(reg, name_idx, self.compile_default_expr(name, expr)!);
                }
                if (first_default == 0xFFFF) first_default = arg_count - 1;
            }
            if (first_default == 0xFFFF) formals++;
        }
    }
    self.in_formal_params = false;
    self.num_args = arg_count;
    self.formal_count = formals;
    self.gen_line(tree.field(rec, ast::FN_HEADER_END));
    self.declare_param_pattern(param_binds.array_view());
    self.index_captures_of(scope);
    self.apply_capture_set();
    self.reserve_arguments_register();
    if (self.has_destructured_param) {
        self.gen_pattern_parameters(params, param_binds.array_view())!;
    } else {
        self.emit_param_prologue(arg_count, first_default, param_name_view(&param_names, arg_count))!;
    }
    bool has_defaults = self.defaults.len() > 0 || self.ast_param_scope;
    if (self.is_user_generator) self.emit_simple(Opcode.GEN_START);
    if (has_defaults) self.emit_simple(Opcode.PUSH_VAR);
    if (arrow) self.emit_simple(Opcode.PUSH_LEX);

    self.hoist_decls_in(scope, false, false)!;
    self.reserved_regs = self.next_reg;

    uint body = tree.field(rec, ast::FN_BODY);
    if ((fnf & ast::FNF_EXPR_BODY) != 0) {
        Val v = self.gen_expr(body, 0)!;
        self.gen_line_end(body);
        self.emit_a_bc(Opcode.RET, (uint)v.reg, 0);
    } else {
        self.gen_function_body(body)!;
    }
    if (gen_trace) io::eprintfn("AST-GEN function at %d", tree.position(tree.field(rec, ast::FN_SRC_START)).line);
    if (has_defaults && !arrow) {
        self.emit_simple(Opcode.POP_VAR);
        self.emit_simple(Opcode.POP_LEX);
    }

    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        has_return = last_op == Opcode.RET || last_op == Opcode.RETUNDEF
            || last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN;
    }
    if (has_return && self.branch_targets_fall_off_end()) has_return = false;
    if (!has_return) {
        self.gen_line(tree.field(rec, ast::FN_SRC_END) - 1);
        self.emit_simple(self.is_user_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }
    if (arrow) {
        self.emit_simple(Opcode.POP_LEX);
        if (has_defaults) {
            self.emit_simple(Opcode.POP_VAR);
            self.emit_simple(Opcode.POP_LEX);
        }
        self.emit_simple(Opcode.POP_VAR);
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
    if (!is_body || !self.is_arrow) self.push_scope_marker(is_body);
    uint stmts = tree.lhs.data[n];
    bool has_lex = false;
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint stmt = tree.list_item(stmts, i);
        if (tree.tags.data[stmt] == NodeTag.CLASS_DECL || (!is_body && self.gen_block_function_node(stmt) != 0)) has_lex = true;
        if (tree.tags.data[stmt] == NodeTag.VAR_DECL
            && (tree.flags.data[stmt] & ast::VAR_KIND_MASK) != ast::VAR_KIND_VAR) has_lex = true;
    }
    bool push_lex = has_lex && !(is_body && self.is_arrow);
    self.gen_line_main(n);
    if (push_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
    }
    if (has_lex && !(is_body && self.is_arrow)) self.gen_tdz(stmts, saved_depth);
    if (is_body) {
        self.gen_line_main(n);
        uint count = tree.list_len(stmts);
        uint i = 0;
        while (i < count && tree.tags.data[tree.list_item(stmts, i)] == NodeTag.DIRECTIVE) {
            self.gen_line_end(tree.list_item(stmts, i++));
        }
        self.emit_hoisted_fn_decls();
        if (has_lex && self.is_arrow) self.gen_tdz(stmts, saved_depth);
    }
    if (!is_body && self.cur_with_depth == 0) self.gen_block_functions(stmts, saved_depth)!;
    if (!self.gen_projection_block(stmts)!) {
        for (uint i = 0; i < tree.list_len(stmts); i++) self.gen_stmt(tree.list_item(stmts, i))!;
    }
    self.gen_line_end(n);
    if (push_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

fn void CompilerContext.gen_tdz(&self, uint stmts, uint outer_depth) {
    ast::Ast* tree = &ast::index_state.tree;
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint stmt = tree.list_item(stmts, i);
        if (tree.tags.data[stmt] == NodeTag.EXPORT_DEFAULT) {
            uint value = tree.lhs.data[stmt];
            if ((tree.flags.data[stmt] & ast::EXPORT_DEFAULT_EXPR) != 0 || (tree.tags.data[value] == NodeTag.CLASS_DECL && tree.lhs.data[value] == 0)) {
                self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant("*default*"));
                continue;
            }
            stmt = value;
        } else if (tree.tags.data[stmt] == NodeTag.EXPORT_DECL) {
            stmt = tree.lhs.data[stmt];
        }
        if (tree.tags.data[stmt] == NodeTag.CLASS_DECL) {
            self.gen_tdz_pattern(tree.lhs.data[stmt], outer_depth);
            continue;
        }
        if (tree.tags.data[stmt] != NodeTag.VAR_DECL
            || (tree.flags.data[stmt] & ast::VAR_KIND_MASK) == ast::VAR_KIND_VAR) continue;
        uint decls = tree.lhs.data[stmt];
        for (uint j = 0; j < tree.list_len(decls); j++) {
            uint id = tree.lhs.data[tree.list_item(decls, j)];
            self.gen_tdz_pattern(id, outer_depth);
        }
    }
}

// ---- statements ----

fn void? CompilerContext.gen_stmt(&self, uint n) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    ushort stmt_base = self.next_reg;
    self.gen_line(tree.main_tok.data[n]);
    switch (tree.tags.data[n]) {
        case EMPTY_STMT:
        case DEBUGGER:
            break;
        case DIRECTIVE:
            if (self.eval_mode) {
                Val value = self.gen_expr(tree.lhs.data[n], 0)!;
                self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)value.reg, 0);
                self.free_val(value);
            }
        case IMPORT_DECL:
        case EXPORT_NAMED:
        case EXPORT_ALL:
            break;
        case EXPORT_DECL:
            self.gen_stmt(tree.lhs.data[n])!;
        case EXPORT_DEFAULT:
            if ((tree.flags.data[n] & ast::EXPORT_DEFAULT_EXPR) == 0) {
                self.gen_stmt(tree.lhs.data[n])!;
            } else {
                NameEvalFrame names = self.save_name_eval();
                defer self.restore_name_eval(names);
                self.has_inferred_name = true;
                self.inferred_name = "default";
                Val value = self.gen_expr(tree.lhs.data[n], 0)!;
                self.emit_a_bc(Opcode.DECLVAR, (uint)value.reg, self.add_string_constant("*default*"));
                self.free_val(value);
            }
        case FUNC_DECL:
            self.gen_function_stmt(n)!;
        case BLOCK:
            self.gen_block(n, false)!;
        case CLASS_DECL:
            self.free_val(self.gen_class(n)!);
        case TRY:
            self.gen_try(n)!;
        case SWITCH:
            self.gen_switch(n)!;
        case EXPR_STMT:
            Val v = self.gen_expr(tree.lhs.data[n], self.eval_mode ? 0 : CTX_STMT)!;
            if (self.eval_mode) self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)v.reg, 0);
            if (v.reg + 1 != self.next_reg || !self.is_local_var_reg(v.reg)) self.free_reg(v.reg);
        case THROW:
            Val v = self.gen_expr(tree.lhs.data[n], 0)!;
            self.gen_line_end(tree.lhs.data[n]);
            self.emit_abc(Opcode.THROW, (uint)v.reg, 0, 0);
        case RETURN:
            uint arg = tree.lhs.data[n];
            if (arg == 0) {
                self.emit_return_iter_closes();
                self.emit_simple(self.is_user_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
            } else {
                Val v = self.gen_expr(arg, 0)!;
                self.gen_line_end(arg);
                if (self.is_async_gen()) {
                    v.reg = self.emit_await(v.reg);
                }
                self.emit_return_iter_closes();
                self.emit_abc(self.is_user_generator ? Opcode.RET_GEN : Opcode.RET, (uint)v.reg, 0, 0);
            }
        case VAR_DECL:
            self.gen_var_decl(n)!;
        case IF:
            self.gen_if(n)!;
        case WHILE:
            self.gen_while(n)!;
        case WITH:
            Val object = self.gen_expr(tree.lhs.data[n], 0)!;
            self.gen_line_main(tree.rhs.data[n]);
            self.emit_a_bc(Opcode.WITH_START, (uint)object.reg, 0);
            self.cur_with_depth++;
            self.has_with_stmt = true;
            if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
            self.gen_stmt(tree.rhs.data[n])!;
            self.gen_line_end(n);
            self.emit_simple(Opcode.WITH_END);
            self.cur_with_depth--;
            self.free_val(object);
        case DO_WHILE:
            self.gen_do_while(n)!;
        case FOR:
            self.gen_for(n)!;
        case FOR_IN:
        case FOR_OF:
            self.gen_for_each(n)!;
        case BREAK:
        case CONTINUE:
            self.gen_loop_jump(n)!;
        case LABELED:
            self.gen_label(n)!;
        default:
            return self.fail("unsupported statement in AST generation")~;
    }
    self.reclaim_stmt_regs(stmt_base);
}

fn void? CompilerContext.gen_var_decl(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    char decl_kind = tree.flags.data[n] & ast::VAR_KIND_MASK;
    bool lexical = decl_kind != ast::VAR_KIND_VAR;
    bool constant = decl_kind == ast::VAR_KIND_CONST;
    ScopeKind kind = constant ? CONST : lexical ? LET : VAR;
    if (!lexical) self.has_local_bindings = true;
    uint decls = tree.lhs.data[n];
    for (uint i = 0; i < tree.list_len(decls); i++) {
        uint d = tree.list_item(decls, i);
        self.gen_line_main(tree.lhs.data[d]);
        uint pattern = tree.lhs.data[d];
        if (tree.tags.data[pattern] != NodeTag.IDENT) {
            self.gen_destruct_decl(pattern, tree.rhs.data[d], kind)!;
            continue;
        }
        char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[d]]);
        uint init = tree.rhs.data[d];
        if (self.is_global && !lexical && init == 0) continue;
        ushort reg;
        bool already_declared = false;
        ushort? existing = lexical ? SCOPE_ERROR~ : self.find_local_reg(name);
        if (try reg_existing = existing) {
            reg = reg_existing;
            already_declared = true;
        } else {
            reg = self.declare_var(name, kind);
        }
        ushort with_base = REG_NONE;
        uint name_idx = self.add_string_constant(name);
        if (!lexical && init != 0 && self.in_with()) {
            with_base = self.alloc_reg();
            self.emit_a_bc(Opcode.WITHBASE, (uint)with_base, name_idx);
        }
        if (init != 0) {
            NameEvalFrame nef = self.save_name_eval();
            defer self.restore_name_eval(nef);
            self.has_inferred_name = true;
            self.inferred_name = name;
            Val v = self.gen_expr(init, 0)!;
            self.gen_line_end(init);
            if (v.reg != reg) self.emit_abc(Opcode.LDREG, (uint)reg, (uint)v.reg, 0);
            self.free_reg(v.reg);
        } else if (!already_declared) {
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
        }
        if ((!already_declared || init != 0) && !(kind == ScopeKind.VAR && self.is_slot_global_name(name))) {
            if (with_base != REG_NONE) {
                ushort value = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)value, (uint)reg, 0);
                self.emit_abc(Opcode.WTWR, (uint)value, (uint)with_base, name_idx);
                self.free_reg(value);
            } else if (init == 0 && !lexical) {
                self.emit_a_bc(Opcode.DECLVAR_HOIST, (uint)reg, name_idx);
            } else {
                bool walk_chain = !lexical && (self.is_global || self.in_with() || (already_declared && self.names_catch_param(name)));
                self.emit_var_store(reg, name_idx, lexical, constant, walk_chain);
            }
        }
        self.free_reg(with_base);
    }
}

// ---- control flow ----

fn void? CompilerContext.gen_switch(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    Val disc = self.gen_expr(tree.lhs.data[n], 0)!;
    // Case selectors can assign to the discriminant's binding (§14.12.4).
    if (disc.local && disc.reg == disc.lreg) {
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)disc.reg, 0);
        disc = { saved, false, 0 };
    }
    uint rec = tree.rhs.data[n];
    uint cases = tree.field(rec, 0);
    uint count = tree.list_len(cases);
    self.gen_line(tree.field(rec, 1));
    self.push_loop(self.code_count, false);
    uint saved_depth = self.scope_depth;
    self.push_scope_marker();
    bool has_lex = false;
    for (uint i = 0; i < count; i++) {
        uint stmts = tree.field(tree.rhs.data[tree.list_item(cases, i)], 0);
        for (uint j = 0; j < tree.list_len(stmts); j++) {
            uint stmt = tree.list_item(stmts, j);
            if (tree.tags.data[stmt] == NodeTag.CLASS_DECL || self.gen_block_function_node(stmt) != 0
                || (tree.tags.data[stmt] == NodeTag.VAR_DECL
                    && (tree.flags.data[stmt] & ast::VAR_KIND_MASK) != ast::VAR_KIND_VAR)) has_lex = true;
        }
    }
    if (has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        for (uint i = 0; i < count; i++) self.gen_tdz(tree.field(tree.rhs.data[tree.list_item(cases, i)], 0), saved_depth);
    }
    if (self.cur_with_depth == 0) {
        for (uint i = 0; i < count; i++) self.gen_block_functions(tree.field(tree.rhs.data[tree.list_item(cases, i)], 0), saved_depth)!;
    }
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    List{SwitchClause} clauses;
    clauses.init(mem, initial_capacity: count);
    defer clauses.free();
    uint default_idx = count;
    for (uint i = 0; i < count; i++) {
        uint c = tree.list_item(cases, i);
        uint test = tree.lhs.data[c];
        ushort base = self.next_reg;
        uint skip;
        if (test != 0) {
            Val v = self.gen_expr(test, 0)!;
            self.gen_line(tree.field(tree.rhs.data[c], 1));
            ushort cmp = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp, (uint)disc.reg, (uint)v.reg);
            skip = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cmp);
            self.free_regs_to(base);
        } else {
            default_idx = i;
            self.gen_line(tree.field(tree.rhs.data[c], 1));
            skip = self.emit_jump(Opcode.JUMP);
        }
        uint body_pc = self.code_count;
        uint stmts = tree.field(tree.rhs.data[c], 0);
        for (uint j = 0; j < tree.list_len(stmts); j++) self.gen_stmt(tree.list_item(stmts, j))!;
        self.gen_line_end(c);
        clauses.push({ body_pc, self.emit_jump(Opcode.JUMP) });
        self.patch_jump(skip);
        if (test == 0 && i + 1 == count) self.code[skip] = bytecode::make_sabc(Opcode.JUMP, (int)body_pc - (int)skip - 1);
    }
    self.gen_line_end(n);
    if (default_idx + 1 < count) {
        uint jump = self.emit_jump(Opcode.JUMP);
        self.code[jump] = bytecode::make_sabc(Opcode.JUMP, (int)clauses[default_idx].body_addr - (int)jump - 1);
    }
    uint end_pc = self.code_count;
    if (has_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.pop_scope_to(saved_depth);
    self.pop_loop();
    foreach (i, clause : clauses) {
        uint target = i + 1 < clauses.len() ? clauses[i + 1].body_addr : end_pc;
        self.code[clause.ft_jump_addr] = bytecode::make_sabc(Opcode.JUMP, (int)target - (int)clause.ft_jump_addr - 1);
    }
    self.free_val(disc);
}

fn void? CompilerContext.gen_try(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    uint param = tree.field(rec, 0);
    uint handler = tree.field(rec, 1);
    uint finalizer = tree.field(rec, 2);
    uint try_pc = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint finally_slot = self.emit_a_bc(Opcode.NOP, 0, 0);
    self.try_depth++;
    ushort completion = self.eval_mode ? self.alloc_reg() : 0;
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    self.gen_block(tree.lhs.data[n], false)!;
    self.emit_simple(Opcode.ENDTRY);
    uint skip = self.emit_jump(Opcode.JUMP);
    uint catch_pc = self.code_count;
    if (handler != 0) {
        uint saved_depth = self.scope_depth;
        ushort saved_reg = self.next_reg;
        bool catch_scope = false;
        self.gen_line(tree.field(rec, 3));
        if (param != 0 && tree.tags.data[param] != NodeTag.IDENT) {
            ushort value = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)value, 0, 0);
            self.emit_a_bc(Opcode.PUSH_LEX, 1, 0);
            self.cur_lex_depth++;
            catch_scope = true;
            DestructBinds binds = { .allocator = mem };
            defer free_destruct_binds(&binds);
            self.gen_collect_pattern(param, &binds)!;
            self.gen_tdz_pattern(param, saved_depth);
            self.gen_declare_pattern(binds.array_view(), LET, true);
            self.gen_line(tree.field(rec, 3));
            self.emit_destructure(binds.array_view(), tree.tags.data[param] == NodeTag.OBJECT_PAT,
                value, DECLARE, true)!;
        } else if (param != 0) {
            char[] name = self.gen_name(tree.lhs.data[param]);
            ushort reg = self.declare_var(name, VAR, true);
            bool captured = self.is_captured_name(name) || self.is_global || self.outer_with || self.scan_has_with;
            if (captured) {
                self.mark_scope_catch_param(self.scope_depth - 1);
                self.mark_scope_captured(self.scope_depth - 1);
            }
            self.emit_abc(Opcode.CATCH, (uint)reg, 0, 0);
            if (captured) {
                self.emit_a_bc(Opcode.PUSH_LEX, 1, 0);
                self.cur_lex_depth++;
                catch_scope = true;
                self.emit_a_bc(Opcode.PUTLEX, (uint)reg, self.add_string_constant(name));
            }
        } else {
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)reg, 0, 0);
            self.free_reg(reg);
        }
        if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
        self.gen_block(handler, false)!;
        if (catch_scope) {
            self.emit_simple(Opcode.POP_LEX);
            self.cur_lex_depth--;
        }
        self.pop_scope_to(saved_depth);
        self.free_regs_to(saved_reg);
    }
    uint finally_pc = finalizer != 0 ? self.code_count : 0;
    self.patch_jump(skip);
    if (finalizer != 0) {
        self.gen_line(tree.field(rec, 4));
        self.emit_simple(Opcode.FINALLY);
        if (self.eval_mode) {
            self.emit_abc(Opcode.LDREG, (uint)completion, (uint)self.eval_acc_reg, 0);
            self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
        }
        self.gen_block(finalizer, false)!;
        if (self.eval_mode) self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)completion, 0);
        self.emit_simple(Opcode.ENDFINALLY);
    }
    if (self.eval_mode) self.free_reg(completion);
    uint flags = (handler != 0 ? 1u : 0u) | (finalizer != 0 ? 2u : 0u);
    self.code[try_pc] = bytecode::make_a_bc(Opcode.TRY, flags, catch_pc - try_pc);
    self.code[finally_slot] = bytecode::make_a_bc(Opcode.NOP, 0, finalizer != 0 ? finally_pc - try_pc : 0);
    self.try_depth--;
}

fn void? CompilerContext.gen_if(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    uint cons = tree.field(rec, 0);
    uint alt = tree.field(rec, 1);
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    Val cond = self.gen_expr(tree.lhs.data[n], 0)!;
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
        Val cond = self.gen_expr(test, 0)!;
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
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    uint cond_jump = 0;
    if (!const_true) cond_jump = self.emit_jump(Opcode.JUMP);
    uint body_label = self.code_count;
    self.push_loop(body_label, true);
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    self.gen_stmt(tree.rhs.data[n])!;
    self.gen_line_end(tree.rhs.data[n]);
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
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    self.gen_stmt(tree.lhs.data[n])!;
    self.gen_line_end(tree.lhs.data[n]);
    self.innermost_loop().continue_target = self.code_count;
    Val cond = self.gen_expr(tree.rhs.data[n], 0)!;
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
    bool lexical = init != 0 && tree.tags.data[init] == NodeTag.VAR_DECL
        && (tree.flags.data[init] & ast::VAR_KIND_MASK) != ast::VAR_KIND_VAR;
    bool constant = lexical && (tree.flags.data[init] & ast::VAR_KIND_MASK) == ast::VAR_KIND_CONST;
    bool per_iter = false;
    PerIterBindings bindings;
    bindings.init(mem);
    defer bindings.free();

    bool patterns = false;
    if (init != 0 && tree.tags.data[init] == NodeTag.VAR_DECL) {
        uint decls = tree.lhs.data[init];
        for (uint i = 0; i < tree.list_len(decls); i++) {
            patterns |= tree.tags.data[tree.lhs.data[tree.list_item(decls, i)]] != NodeTag.IDENT;
        }
    }
    if (patterns) {
        if (lexical) {
            self.emit_simple(Opcode.PUSH_LEX);
            self.cur_lex_depth++;
            uint decls = tree.lhs.data[init];
            for (uint i = 0; i < tree.list_len(decls); i++) {
                self.gen_tdz_pattern(tree.lhs.data[tree.list_item(decls, i)], saved_scope);
            }
        }
        self.gen_var_decl(init)!;
        if (lexical) {
            for (uint i = saved_scope; i < self.scope_depth; i++) {
                ScopeEntry* entry = &self.scope_stack[i];
                if (entry.kind != LET && entry.kind != CONST) continue;
                bindings.push({ self.add_string_constant(entry.name), constant });
                per_iter |= self.is_captured_name(entry.name);
            }
        }
    } else if (init != 0 && tree.tags.data[init] == NodeTag.VAR_DECL) {
        uint decls = tree.lhs.data[init];
        for (uint i = 0; i < tree.list_len(decls); i++) {
            uint d = tree.list_item(decls, i);
            char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[d]]);
            uint value = tree.rhs.data[d];
            // Hoisting owns the binding; an uninitialized var performs no store (§14.3.2.1).
            if (value == 0 && !lexical) continue;
            ushort reg;
            bool env_resident = false;
            if (i == 0) {
                if (try existing = (lexical ? SCOPE_ERROR~ : self.find_local_reg(name))) {
                    reg = existing;
                    env_resident = self.is_existing_local_env_resident(name);
                } else {
                    reg = self.declare_var(name, constant ? CONST : lexical ? LET : VAR);
                }
                has_for_var = !lexical && !self.is_global && !self.is_captured_name(name);
                if (has_for_var) {
                    if (catch self.resolve_var(name)) has_for_var = false;
                }
                for_var_reg = reg;
                for_var_name_idx = self.add_string_constant(name);
                if (lexical) {
                    self.gen_line_main(tree.lhs.data[d]);
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                    for (uint j = 0; j < tree.list_len(decls); j++) {
                        uint id = tree.lhs.data[tree.list_item(decls, j)];
                        char[] head_name = self.gen_name(tree.lhs.data[id]);
                        self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(head_name));
                        for (uint k = 0; k < saved_scope; k++) {
                            if (str_eq(self.scope_stack[k].name, head_name)) { self.mark_scope_captured(k); break; }
                        }
                    }
                }
            } else if (try existing = (lexical ? SCOPE_ERROR~ : self.resolve_var(name))) {
                reg = existing;
            } else {
                reg = self.declare_var(name, constant ? CONST : lexical ? LET : VAR);
            }
            uint name_idx = i == 0 ? for_var_name_idx : self.add_string_constant(name);
            if (lexical) {
                bindings.push({ name_idx, constant });
                per_iter |= self.is_captured_name(name);
            }
            if (value != 0) {
                Val v = self.gen_expr(value, 0)!;
                if (v.reg != reg) self.emit_abc(Opcode.LDREG, (uint)reg, (uint)v.reg, 0);
                self.free_reg(v.reg);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }
            self.emit_var_store(reg, name_idx, lexical, constant, env_resident);
        }
    } else if (init != 0) {
        Val v = self.gen_expr(init, 0)!;
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
    if (per_iter) self.emit_create_per_iteration_env(bindings.array_view());
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    uint cond_jump = 0;
    if (test != 0) cond_jump = self.emit_jump(Opcode.JUMP);
    uint body_label = self.code_count;
    self.push_loop(body_label, true);
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    self.gen_stmt(body)!;
    self.gen_line_end(body);
    self.innermost_loop().continue_target = self.code_count;
    if (per_iter) self.emit_create_per_iteration_env(bindings.array_view());
    if (update != 0) {
        self.gen_line(tree.main_tok.data[update]);
        if (self.next_reg < cond_floor) self.next_reg = cond_floor;
        Val v = self.gen_expr(update, CTX_STMT)!;
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
    if (lexical) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    if (has_for_var && !iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

fn void? CompilerContext.gen_label(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint body = tree.rhs.data[n];
    uint item = body;
    while (tree.tags.data[item] == NodeTag.LABELED) item = tree.rhs.data[item];
    NodeTag tag = tree.tags.data[item];
    bool loop = tag == NodeTag.FOR || tag == NodeTag.WHILE || tag == NodeTag.DO_WHILE
        || tag == NodeTag.FOR_IN || tag == NodeTag.FOR_OF;
    if (!loop) self.push_loop(self.code_count, false);
    self.labels.push({ .name = self.gen_name(tree.lhs.data[n]), .is_loop = loop,
        .loop_index = self.loop_depth() - (loop ? 0u : 1u) });
    self.gen_stmt(body)!;
    self.labels.remove_last()!!;
    if (!loop) self.pop_loop();
}

fn void CompilerContext.gen_remove_member_read(&self, bool super) {
    if (super) {
        self.code_count--;
        if (self.code_count > 0 && self.code[self.code_count - 1].op == Opcode.WIDE) self.code_count--;
    }
    self.code_count--;
    if (self.code_count > 0 && self.code[self.code_count - 1].op == Opcode.WIDE) self.code_count--;
}

fn void? CompilerContext.gen_member_bind(&self, uint target_node, ushort value) {
    ushort floor = self.next_reg;
    if (ast::index_state.tree.tags.data[target_node] == NodeTag.CALL) {
        self.gen_invalid_call_target(target_node)!;
        self.free_regs_to(floor);
        return;
    }
    MemberTarget target = self.gen_member_target(target_node)!;
    self.gen_remove_member_read(target.super);
    self.emit_abc(target.super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP,
        (uint)target.base.reg, (uint)target.key, (uint)value);
    self.free_regs_to(floor);
}

fn void? CompilerContext.gen_for_each(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    bool of = tree.tags.data[n] == NodeTag.FOR_OF;
    bool is_await = (tree.flags.data[n] & ast::FOR_AWAIT) != 0;
    uint lhs = tree.lhs.data[n];
    uint rec = tree.rhs.data[n];
    uint rhs = tree.field(rec, 0);
    uint body = tree.field(rec, 1);
    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;
    bool declared = tree.tags.data[lhs] == NodeTag.VAR_DECL;
    bool lexical = declared && (tree.flags.data[lhs] & ast::VAR_KIND_MASK) != ast::VAR_KIND_VAR;
    bool constant = lexical && (tree.flags.data[lhs] & ast::VAR_KIND_MASK) == ast::VAR_KIND_CONST;
    uint init = 0;
    if (declared) {
        uint decl = tree.list_item(tree.lhs.data[lhs], 0);
        init = tree.rhs.data[decl];
        lhs = tree.lhs.data[decl];
    }
    if (tree.tags.data[lhs] == NodeTag.ARRAY_PAT || tree.tags.data[lhs] == NodeTag.OBJECT_PAT) {
        self.gen_for_pattern(n, lhs, declared, lexical, constant, saved_scope, saved_reg)!;
        return;
    }
    bool member = tree.tags.data[lhs] != NodeTag.IDENT;
    char[] name = member ? "" : self.gen_name(tree.lhs.data[lhs]);
    ushort binding = REG_NONE;
    bool walk_chain = false;
    uint name_idx = uint::max;
    if (declared && !of) {
        if (!lexical) walk_chain = self.is_existing_local_env_resident(name);
        binding = self.declare_binding_var(name, constant ? CONST : lexical ? LET : VAR);
    }
    if (lexical) {
        // RHS closures retain the head's uninitialised environment, separately from iterations.
        for (uint i = 0; i < saved_scope; i++) {
            if (str_eq(self.scope_stack[i].name, name)) { self.mark_scope_captured(i); break; }
        }
        if (!of) self.mark_scope_captured(self.scope_depth - 1);
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
    }
    if (init != 0) {
        NameEvalFrame names = self.save_name_eval();
        defer self.restore_name_eval(names);
        self.has_inferred_name = true;
        self.inferred_name = name;
        Val v = self.gen_expr(init, 0)!;
        self.emit_abc(Opcode.LDREG, (uint)binding, (uint)v.reg, 0);
        self.free_val(v);
        name_idx = self.add_string_constant(name);
        self.emit_var_store(binding, name_idx, false, false, walk_chain);
    }
    Val source = self.gen_expr(rhs, 0)!;
    self.gen_line_end(rhs);
    if (lexical) {
        self.emit_simple(of ? Opcode.POP_LEX : Opcode.PUSH_LEX);
        self.cur_lex_depth += of ? -1 : 1;
    }
    self.gen_line(tree.field(rec, 2));
    if (of) {
        if (member) {
            ForOfHead head = { .kind = MEMBER, .ast_target = lhs };
            self.emit_forof(head, source.reg, saved_scope, saved_reg, is_await, body)!;
        } else {
            self.emit_forof_loop(name, source.reg, saved_scope, saved_reg, lexical, constant,
                !declared, is_await, ast_body: body)!;
        }
        return;
    }
    if (name_idx == uint::max && !member) name_idx = self.add_string_constant(name);
    ushort key = declared ? REG_NONE : self.alloc_reg();
    ushort home = REG_NONE;
    if (!declared && !member && !self.is_global) home = self.resolve_var(name) ?? REG_NONE;
    ushort state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)source.reg, (uint)state, 0);
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    uint loop = self.code_count;
    self.push_loop(loop, true);
    if (declared) key = self.alloc_reg();
    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)key, (uint)has_next, (uint)state);
    uint exit = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);
    if (member) {
        self.gen_member_bind(lhs, key)!;
    } else if (declared) {
        self.emit_abc(Opcode.LDREG, (uint)binding, (uint)key, 0);
        self.emit_var_store(binding, name_idx, lexical, constant, walk_chain);
    } else if (home != REG_NONE) {
        self.emit_abc(Opcode.LDREG, (uint)home, (uint)key, 0);
        uint const_name = self.find_const_name_idx(home);
        if (const_name != uint::max) self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)home, const_name);
    } else {
        self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)key, name_idx);
    }
    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    self.gen_stmt(body)!;
    self.gen_line_end(body);
    self.innermost_loop().continue_target = self.code_count;
    if (lexical && self.is_captured_name(name)) {
        PerIterBinding[1] cycle = { { name_idx, constant } };
        self.emit_create_per_iteration_env(cycle[..]);
    }
    self.emit(bytecode::make_sabc(Opcode.JUMP, (int)loop - (int)self.code_count - 1));
    self.patch_jump(exit);
    self.pop_loop();
    if (lexical) {
        self.emit_simple(Opcode.POP_LEX);
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth -= 2;
    }
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

fn void? CompilerContext.gen_loop_jump(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    bool cont = tree.tags.data[n] == NodeTag.CONTINUE;
    uint atom = tree.lhs.data[n];
    int target = (int)self.loop_depth() - 1;
    if (atom != 0) {
        target = -1;
        char[] name = self.gen_name(atom);
        foreach (label : self.labels) {
            if (str_eq(label.name, name)) { target = (int)label.loop_index; break; }
        }
        self.gen_line_end(n);
    } else if (cont) {
        while (target >= 0 && !self.loop_stack[target].is_loop) target--;
    }
    if (target < 0) return COMPILE_ERROR~;
    // An abrupt edge leaves these scopes; other edges still compile at their original depth.
    for (int depth = self.cur_lex_depth; depth > self.loop_stack[target].saved_lex_depth; depth--) {
        self.emit_simple(Opcode.POP_LEX);
    }
    for (int depth = self.cur_with_depth; depth > self.loop_stack[target].saved_with_depth; depth--) {
        self.emit_simple(Opcode.WITH_END);
    }
    for (int i = (int)self.loop_depth() - 1; i >= target + (cont ? 1 : 0); i--) {
        if (self.loop_stack[i].iter_close_reg >= 0) self.emit_unwind_iter_close((uint)i);
    }
    uint jump = self.emit_jump(self.loop_jump_op((uint)target, cont ? Opcode.CONTINUE : Opcode.BREAK));
    if (cont) {
        self.loop_stack[target].continue_patch_head = self.add_patch(self.loop_stack[target].continue_patch_head, jump);
    } else {
        self.loop_stack[target].break_patch_head = self.add_patch(self.loop_stack[target].break_patch_head, jump);
    }
}

// ---- expressions ----

// What the value of an expression is used for. CTX_VOID: an assignment skips its result-preserving
// move. CTX_POSTFIX: a postfix update skips materialising the old value. An expression statement
// and a `for` update clause carry both; parentheses and every operator other than `,` drop them.
const uint CTX_VOID = 1;
const uint CTX_POSTFIX = 2;
const uint CTX_STMT = CTX_VOID | CTX_POSTFIX;

// Compile expression `n` for the uses `ctx` names.
fn Val? CompilerContext.gen_expr(&self, uint n, uint ctx) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    if (n != 0) {
        if (n == self.projection_node) return self.gen_spread_projection(n);
        if (n == self.projection_source) return (Val){ self.projection_source_reg, true, self.projection_source_reg };
        if (n == self.projection_member) return self.gen_expr(tree.lhs.data[n], ctx);
    }
    Val selected;
    if (self.gen_literal_member(n, &selected)!) return selected;
    if (self.scalar_fields != null && tree.tags.data[n] == NodeTag.MEMBER
        && tree.tags.data[tree.lhs.data[n]] == NodeTag.THIS) {
        for (uint i = 0; i < self.scalar_fields.field_count; i++) {
            if (self.scalar_fields.field_names[i] != tree.rhs.data[n]) continue;
            ushort reg = (ushort)(self.scalar_first_arg + self.scalar_fields.field_args[i]);
            return { reg, true, reg };
        }
    }
    bool outer_parens = self.inside_parens;
    defer self.inside_parens = outer_parens;
    if ((tree.flags.data[n] & ast::FLAG_PAREN) != 0) {
        ctx = 0;
        self.inside_parens = true;
    }
    if (!self.disable_optimize && (tree.tags.data[n] == NodeTag.BINARY || tree.tags.data[n] == NodeTag.UNARY)) {
        uint budget = 32;
        TVal value;
        if (fold_number(tree, n, &budget, &value)) {
            self.gen_line_end(n);
            if (value.is_number()) return self.gen_number(value.get_number());
            ushort reg = self.alloc_reg();
            self.emit_abc(value.get_boolean() ? Opcode.LDTRUE : Opcode.LDFALSE, (uint)reg, 0, 0);
            return { reg, false, 0 };
        }
    }
    switch (tree.tags.data[n]) {
        case NUMBER:
        case BIGINT:
        case STRING:
        case REGEX:
        case NEW_TARGET:
        case THIS:
        case NULL_LIT:
        case TRUE_LIT:
        case FALSE_LIT:
        case IDENT:
            self.gen_line_main(n);
        default:
            break;
    }
    switch (tree.tags.data[n]) {
        case NUMBER:
            ulong bits = ((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n];
            return self.gen_number(bitcast(bits, double));
        case STRING:
            uint idx = self.add_string_constant(tree.atoms.get(tree.lhs.data[n]));
            ushort reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)reg, idx);
            return { reg, false, 0 };
        case BIGINT:
        case REGEX:
            char[] text = tree.atoms.get(tree.lhs.data[n]);
            uint idx = tree.tags.data[n] == NodeTag.BIGINT
                ? self.add_bigint_constant(text)! : self.add_string_constant(text);
            ushort reg = self.alloc_reg();
            self.emit_a_bc(tree.tags.data[n] == NodeTag.BIGINT ? Opcode.LDCONST : Opcode.NEWREGEXP,
                (uint)reg, idx);
            return { reg, false, 0 };
        case IMPORT_META:
            self.gen_line_end(n);
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.IMPORT_META, (uint)reg, 0, 0);
            return { reg, false, 0 };
        case IMPORT_CALL:
            return self.gen_import(n);
        case CLASS_EXPR:
            return self.gen_class(n);
        case SUPER_CALL:
            return self.gen_super_call(n);
        case PRIVATE_IN:
            return self.gen_private_in(n);
        case NEW_TARGET:
            self.gen_line_end(n);
            ushort reg = self.alloc_reg();
            self.emit_abc(Opcode.NEWTARGET, (uint)reg, 0, 0);
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
        case FUNC_EXPR:
        case ARROW:
            return self.gen_closure(n);
        case IDENT:
            return self.gen_ident(n);
        case SEQUENCE:
            return self.gen_sequence(n, ctx);
        case TEMPLATE:
            return self.gen_template(n);
        case TAGGED_TEMPLATE:
            return self.gen_tagged_template(n);
        case OPT_CHAIN:
            return self.gen_optional_chain(n);
        case BINARY:
        case LOGICAL:
            // A finished operator expression is a value, never a reference to a local.
            Val v = self.gen_binary(n)!;
            v.local = false;
            return v;
        case COND:
            return self.gen_cond(n);
        case ARRAY:
            return self.gen_array(n);
        case OBJECT:
            return self.gen_object(n);
        case NEW:
            return self.gen_new(n);
        case AWAIT:
        case YIELD:
        case YIELD_STAR:
            return self.gen_suspend(n);
        case UNARY:
            return self.gen_unary(n);
        case MEMBER:
        case INDEX:
        case SUPER_MEMBER:
        case SUPER_INDEX:
        case PRIVATE_MEMBER:
        case CALL:
            Phase ph = MEMBER;
            Val v = self.gen_chain(n, &ph)!;
            // A chain with no call frees its pending receiver here.
            if (ph == Phase.MEMBER && self.call_prop_obj_reg != REG_NONE && !self.inside_parens) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = REG_NONE;
            }
            return v;
        case ASSIGN:
            return self.gen_assign(n, ctx);
        case UPDATE_PRE:
        case UPDATE_POST:
            return self.gen_update(n, ctx);
        default:
            return self.fail("unsupported expression in AST generation")~;
    }
}

fn Val? CompilerContext.gen_suspend(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    NodeTag tag = tree.tags.data[n];
    uint arg = tree.lhs.data[n];
    Val v;
    if (arg != 0) v = self.gen_expr(arg, 0)!;
    self.gen_line_end(n);
    if (tag == NodeTag.AWAIT) {
        if (self.is_module) self.saw_top_level_await = true;
        v.reg = self.emit_await(v.reg);
        return v;
    }
    if (tag == NodeTag.YIELD_STAR) {
        if (self.is_async_gen()) {
            ushort iter = self.alloc_reg();
            self.emit_abc(Opcode.GET_ITER_ASYNC, (uint)iter, (uint)v.reg, 0);
            self.free_val(v);
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.YIELD_STAR_ASYNC, (uint)result, (uint)iter, 0);
            self.free_reg(iter);
            return { result, v.local, v.lreg };
        }
        ushort result = self.alloc_reg();
        self.emit_abc(Opcode.YIELD_STAR, (uint)result, (uint)v.reg, 0);
        self.free_val(v);
        return { result, v.local, v.lreg };
    }
    ushort result = self.alloc_reg();
    if (arg == 0) {
        self.emit_abc(Opcode.LDUNDEF, (uint)result, 0, 0);
    } else {
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)v.reg, 0);
    }
    if (arg != 0 && self.is_async_gen()) {
        self.emit_abc(Opcode.AWAIT, (uint)result, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
    }
    self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
    self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
    if (arg != 0) self.free_val(v);
    return { result, v.local, v.lreg };
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

fn Val? CompilerContext.gen_sequence(&self, uint n, uint ctx) {
    ast::Ast* tree = &ast::index_state.tree;
    uint items = tree.lhs.data[n];
    Val value;
    for (uint i = 0; i < tree.list_len(items); i++) {
        if (i != 0) {
            self.free_val(value);
            self.has_inferred_name = false;
            self.inferred_name = {};
        }
        value = self.gen_expr(tree.list_item(items, i), ctx)!;
        if (self.call_prop_obj_reg != REG_NONE) {
            self.free_reg(self.call_prop_obj_reg);
            self.call_prop_obj_reg = REG_NONE;
        }
    }
    // Keep register ownership so enclosing expressions preserve the value across writes.
    return value;
}

fn Val? CompilerContext.gen_template(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint parts = tree.lhs.data[n];
    uint exprs = tree.template_exprs(parts);
    self.gen_line_main(n);
    ushort result = self.alloc_reg();
    uint count = 0;
    Val last;
    for (uint i = 0; i <= exprs; i++) {
        self.gen_line(tree.template_tok(parts, i));
        char[] text = tree.atoms.get(tree.template_cooked(parts, i));
        if (text.len > 0 || exprs == 0) {
            self.emit_a_bc(Opcode.LDCONST, (uint)result + count, self.add_string_constant(text));
            count++;
            if (exprs != 0 && self.next_reg <= result + count) self.next_reg = (ushort)(result + count + 1);
        }
        if (i == exprs) break;
        uint start = self.code_count;
        Val v = self.gen_expr(tree.template_expr(parts, i), 0)!;
        last = v;
        self.gen_line(tree.template_tok(parts, i + 1));
        bool defer_string = (i + 1 == exprs && tree.atoms.get(tree.template_cooked(parts, i + 1)).len == 0)
            || self.part_producer_kind(start, self.code_count, v.reg, 0) == PartKind.PART_DEFER;
        if (!defer_string) v.reg = self.tostr_into_temp(v.reg);
        self.emit_abc(Opcode.LDREG, (uint)result + count++, (uint)v.reg, 0);
        if (self.next_reg <= result + count) self.next_reg = (ushort)(result + count + 1);
    }
    if (exprs != 0) self.emit_abc(Opcode.STRJOIN, (uint)result, (uint)result, count);
    self.free_regs_to(result + 1);
    return { result, last.local, last.lreg };
}

fn Val? CompilerContext.gen_closure(&self, uint n, uint object_home = uint::max) {
    uint inner_idx = self.add_inner_func(self.gen_compile_function(n, object_home)!);
    self.gen_line_end(n);
    ushort reg = self.alloc_reg();
    self.emit_a_bc(Opcode.CLOSURE, (uint)reg, inner_idx);
    return { reg, false, 0 };
}

fn CompiledFunction*? CompilerContext.gen_compile_function(&self, uint n, uint object_home = 0xFFFFFFFF) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    uint scope = ast::index_state.function_scope(n);
    uint name_node = tree.lhs.data[n];
    uint fnf = tree.field(rec, ast::FN_FLAGS);
    bool method = (fnf & ast::FNF_METHOD) != 0;
    char[] name = name_node != 0 ? self.gen_name(tree.lhs.data[name_node])
        : self.has_inferred_name ? self.inferred_name : "";
    self.has_inferred_name = false;
    self.inferred_name = {};
    bool saved_constructable = self.is_constructable;
    bool saved_gen = self.is_generator;
    bool saved_user_gen = self.is_user_generator;
    bool saved_async = self.is_async;
    self.is_user_generator = (fnf & ast::FNF_GENERATOR) != 0;
    self.is_async = (fnf & ast::FNF_ASYNC) != 0;
    self.is_generator = self.is_user_generator || self.is_async;
    if (tree.tags.data[n] != NodeTag.ARROW) self.is_constructable = !method && !self.is_generator;
    defer {
        self.is_constructable = saved_constructable;
        self.is_generator = saved_gen;
        self.is_user_generator = saved_user_gen;
        self.is_async = saved_async;
    }
    CompiledFunction* inner = tree.tags.data[n] == NodeTag.ARROW
        ? self.compile_arrow_ast(scope, name)!
        : self.compile_inner_function(name, name_node != 0 && tree.tags.data[n] == NodeTag.FUNC_EXPR,
            tree.field(rec, ast::FN_SRC_START), true, is_method_body: method,
            ast_scope: scope, object_home: object_home)!;
    return inner;
}

fn CompiledFunction*? CompilerContext.compile_arrow_ast(&self, uint scope, char[] name) {
    ast::AstIndex* idx = ast::index_state;
    uint rec = idx.tree.rhs.data[idx.res.scopes.data[scope].node];
    CompilerContext arrow_ctx;
    self.init_arrow_context(&arrow_ctx, (idx.tree.field(rec, ast::FN_FLAGS) & ast::FNF_ASYNC) != 0);
    defer arrow_ctx.cleanup();
    defer self.lexer.set_strict(self.is_strict);
    arrow_ctx.gen_function(scope)!;
    CompiledFunction* func = arrow_ctx.finish()!;
    if (arrow_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        func.flags.mapped_arguments = false;
        self.uses_arguments = true;
    }
    attach_function_info(func, name, false, idx.tree.field(rec, ast::FN_SRC_START),
        idx.tree.field(rec, ast::FN_SRC_END), false, self.lexer.source);
    return func;
}



fn Val? CompilerContext.gen_binary(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint current = n;
    List{uint} chain = { .allocator = mem };
    defer chain.free();
    while (true) {
        uint left = tree.lhs.data[current];
        NodeTag tag = tree.tags.data[left];
        if ((tag != NodeTag.BINARY && tag != NodeTag.LOGICAL) || (tree.flags.data[left] & ast::FLAG_PAREN) != 0) {
            Val value = self.gen_binary_step(current, self.gen_expr(left, 0)!)!;
            for (sz i = chain.len(); i > 0;) value = self.gen_binary_step(chain[--i], value)!;
            return value;
        }
        chain.push(current);
        current = left;
    }
}

fn Val? CompilerContext.gen_binary_step(&self, uint n, Val left) {
    ast::Ast* tree = &ast::index_state.tree;
    bool logical = tree.tags.data[n] == NodeTag.LOGICAL;
    TokenType tok = (TokenType)(tree.flags.data[n] & 0x7F);
    self.gen_line_main(n);
    if (logical) return self.gen_logical(n, tok, left);
    Opcode op = token_to_binary_opcode(tok);
    // The left operand's value must survive a right operand that writes its home register.
    if (left.local && self.gen_writes_local(tree.lhs.data[n] + 1, n - 1, left.reg)) {
        self.gen_line_main(n);
        ushort keep = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)keep, (uint)left.reg, 0);
        left.reg = keep;
        left.local = false;
    }
    Val right = self.gen_expr(tree.rhs.data[n], 0)!;
    self.gen_line_end(n);
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

// `&&`, `||` and `??`: the result merges into the left operand's register, so a left operand that
// is a local's home register is copied to a temp first.
fn Val? CompilerContext.gen_logical(&self, uint n, TokenType tok, Val left) {
    ast::Ast* tree = &ast::index_state.tree;
    if (left.local) {
        ushort tmp = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left.reg, 0);
        left.reg = tmp;
    }
    if (tok == TokenType.NULLISH) {
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
        self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left.reg, (uint)cmp_reg);
        uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
        self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
        self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left.reg, (uint)cmp_reg);
        uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
        self.free_reg(cmp_reg);
        uint skip_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(null_jump);
        self.patch_jump(undef_jump);
        Val right = self.gen_expr(tree.rhs.data[n], 0)!;
        self.gen_line_end(n);
        self.emit_abc(Opcode.LDREG, (uint)left.reg, (uint)right.reg, 0);
        self.free_reg(right.reg);
        self.patch_jump(skip_jump);
    } else {
        uint skip_jump = self.emit_cond_jump(tok == TokenType.LOG_AND ? Opcode.IF_FALSE : Opcode.IF_TRUE, (uint)left.reg);
        Val right = self.gen_expr(tree.rhs.data[n], 0)!;
        self.gen_line_end(n);
        self.emit_abc(Opcode.LDREG, (uint)left.reg, (uint)right.reg, 0);
        self.free_reg(right.reg);
        self.patch_jump(skip_jump);
    }
    return { left.reg, false, 0 };
}

// `test ? a : b`. Neither branch is an anonymous function definition's NamedEvaluation site.
fn Val? CompilerContext.gen_cond(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    Val test = self.gen_expr(tree.lhs.data[n], 0)!;
    self.gen_line_main(n);
    self.has_inferred_name = false;
    self.inferred_name = {};
    ushort result = self.alloc_reg();
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)test.reg);
    self.free_reg(test.reg);
    Val yes = self.gen_expr(tree.field(rec, 0), 0)!;
    self.gen_line_end(tree.field(rec, 0));
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)yes.reg, 0);
    self.free_reg(yes.reg);
    self.gen_line(tree.field(rec, 2));
    uint end_jump = self.emit_jump(Opcode.JUMP);
    self.patch_jump(false_jump);
    Val no = self.gen_expr(tree.field(rec, 1), 0)!;
    self.gen_line_end(tree.field(rec, 1));
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)no.reg, 0);
    self.free_reg(no.reg);
    self.patch_jump(end_jump);
    return { result, false, 0 };
}

// ---- assignment and update of an identifier ----

// A bare identifier as the target of an assignment or update: its home register when it is a
// register-resident local, otherwise a temporary holding a by-name read.
struct Target {
    ushort reg;
    bool local;
    bool global;       // the by-name read is a GETGLOBAL
    uint name_idx;
}

fn Target? CompilerContext.gen_target(&self, char[] name) {
    if (try reg = self.resolve_var(name)) return { reg, true, false, 0 };
    uint name_idx = self.add_string_constant(name);
    ushort reg = self.alloc_reg();
    self.emit_ident_read((uint)reg, name_idx)!;
    return { reg, false, self.last_was_getglobal, name_idx };
}

fn Opcode compound_assign_opcode(TokenType tt) {
    switch (tt) {
        case PLUS_ASSIGN: return Opcode.ADD;
        case MINUS_ASSIGN: return Opcode.SUB;
        case STAR_ASSIGN: return Opcode.MUL;
        case SLASH_ASSIGN: return Opcode.DIV;
        case PERCENT_ASSIGN: return Opcode.MOD;
        case STARSTAR_ASSIGN: return Opcode.EXP;
        case SHL_ASSIGN: return Opcode.SHL;
        case SHR_ASSIGN: return Opcode.SHR;
        case USHR_ASSIGN: return Opcode.USHR;
        case BIT_AND_ASSIGN: return Opcode.BAND;
        case BIT_OR_ASSIGN: return Opcode.BOR;
        case BIT_XOR_ASSIGN: return Opcode.BXOR;
        default: return Opcode.NOP;
    }
}

// `x = v` and `x op= v`. The value left behind describes the right operand wherever the fused
// compiler leaves its reference markers untouched.
fn Val? CompilerContext.gen_assign(&self, uint n, uint ctx) {
    ast::Ast* tree = &ast::index_state.tree;
    uint lhs = tree.lhs.data[n];
    if (tree.tags.data[lhs] == NodeTag.CALL) {
        Val value = self.gen_invalid_call_target(lhs)!;
        self.free_val(self.gen_expr(tree.rhs.data[n], 0)!);
        return value;
    }
    if (tree.tags.data[lhs] == NodeTag.ARRAY_PAT || tree.tags.data[lhs] == NodeTag.OBJECT_PAT) {
        return self.gen_destruct_assign(lhs, tree.rhs.data[n]);
    }
    TokenType tt = (TokenType)(tree.flags.data[n] & 0x7F);
    if (tree.tags.data[lhs] == NodeTag.IDENT && self.in_with()) {
        uint name = self.add_string_constant(self.gen_name(tree.lhs.data[lhs]));
        return self.gen_with_assign(n, name, tt);
    }
    if (tt == TokenType.LOG_AND_ASSIGN || tt == TokenType.LOG_OR_ASSIGN || tt == TokenType.NULLISH_ASSIGN) {
        return self.gen_logical_assign(n, tt);
    }
    uint target_node = tree.lhs.data[n];
    if (tree.tags.data[target_node] != NodeTag.IDENT) return self.gen_member_assign(n);
    uint rhs_node = tree.rhs.data[n];
    bool void_ctx = (ctx & CTX_VOID) != 0;
    bool is_assign = tt == TokenType.ASSIGN;
    Opcode compound_op = compound_assign_opcode(tt);
    bool is_compound = !is_assign;
    char[] name = self.gen_name(tree.lhs.data[target_node]);
    bool target_paren = (tree.flags.data[target_node] & ast::FLAG_PAREN) != 0;

    self.gen_line_main(target_node);
    Target t = self.gen_target(name)!;
    ushort left = t.reg;
    uint const_name = t.local ? self.find_const_name_idx(left) : 0xFFFFFFFF;
    bool getvar = !t.local;
    Opcode store_op = t.global ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN;
    ushort ref_reg = REG_NONE;

    // `x -= 1` is a decrement.
    if (is_compound && compound_op == Opcode.SUB && tree.tags.data[rhs_node] == NodeTag.NUMBER
        && (tree.flags.data[rhs_node] & ast::FLAG_PAREN) == 0
        && bitcast(((ulong)tree.rhs.data[rhs_node] << 32) | (ulong)tree.lhs.data[rhs_node], double) == 1.0) {
        self.gen_line_end(n);
        if (!getvar) {
            self.emit_a_bc(const_name != 0xFFFFFFFF ? Opcode.DEC_VAR : Opcode.DEC,
                (uint)left, const_name != 0xFFFFFFFF ? const_name : 0);
            return { left, true, left };
        }
        Instruction last = self.code[self.code_count - 1];
        if (t.global) {
            self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_GLOBAL, (uint)last.a, last.get_bc());
        } else {
            self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, (uint)last.a, last.get_bc());
        }
        return { left, false, 0 };
    }

    // The reference is resolved before the right operand runs, so a binding the operand
    // introduces cannot capture the store.
    if (getvar) {
        bool statically_resolvable = t.global
            ? self.is_declared_global(t.name_idx)
            : (!target_paren && self.is_statically_resolvable_local(name));
        if (is_assign) {
            self.code_count--;
            if (self.code_count > 0 && self.code[self.code_count - 1].op == Opcode.WIDE) self.code_count--;
            if (!statically_resolvable) {
                ref_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.RESOLVEVAR, (uint)ref_reg, t.name_idx);
            }
        } else if (!statically_resolvable) {
            ushort probe = self.alloc_reg();
            self.emit_a_bc(Opcode.RESOLVEVAR, (uint)probe, t.name_idx);
            ref_reg = probe;
        }
    }

    NameEvalFrame nef = self.save_name_eval();
    defer self.restore_name_eval(nef);
    if (is_assign && !target_paren) {
        self.has_inferred_name = true;
        self.inferred_name = name;
    } else {
        self.has_inferred_name = false;
        self.inferred_name = {};
    }

    // `g op= (g = ...)` reads g before the operand overwrites it.
    ushort compound_old = left;
    bool compound_old_copied = false;
    if (is_compound && t.local && self.gen_writes_local(tree.lhs.data[n] + 1, n - 1, left)) {
        self.gen_line_main(n);
        compound_old = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)compound_old, (uint)left, 0);
        compound_old_copied = true;
    }

    Val right = self.gen_expr(rhs_node, 0)!;
    self.gen_line_end(n);

    if (is_assign) {
        if (ref_reg != REG_NONE) self.emit_a_bc(Opcode.THROW_UNRESOLVED, (uint)ref_reg, t.name_idx);
        if (void_ctx && getvar) {
            if (right.local) {
                if (left != right.reg) {
                    self.emit_abc(Opcode.LDREG, (uint)left, (uint)right.reg, 0);
                    self.free_reg(right.reg);
                }
                self.emit_var_store_op(store_op, left, t.name_idx, ref_reg);
                return { left, right.local, right.lreg };
            }
            if (left != right.reg) self.free_reg(left);
            self.emit_var_store_op(store_op, right.reg, t.name_idx, ref_reg);
            return right;
        }
        if (const_name != 0xFFFFFFFF) return self.gen_const_store(right.reg, const_name, void_ctx);
        if (left != right.reg) self.emit_abc(Opcode.LDREG, (uint)left, (uint)right.reg, 0);
        if (!right.local) self.free_reg(right.reg);
        if (getvar) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            self.emit_var_store_op(store_op, left, t.name_idx, ref_reg);
            self.free_reg(left);
            return { tmp, right.local, right.lreg };
        }
        return { left, true, left };
    }

    // `left op= right` computes in place for the operators that read both operands before
    // writing, and through a temporary for the rest.
    ushort result_reg = left;
    bool can_inplace = (compound_op == Opcode.ADD || compound_op == Opcode.SUB || compound_op == Opcode.MUL)
        && left != right.reg;
    if (!getvar && (!can_inplace || const_name != 0xFFFFFFFF)) {
        result_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)left, 0);
    }
    self.emit_abc(compound_op, (uint)result_reg, (uint)compound_old, (uint)right.reg);
    if (const_name != 0xFFFFFFFF) return self.gen_const_store(result_reg, const_name, false);
    if (compound_old_copied) self.free_reg(compound_old);
    if (!right.local) self.free_reg(right.reg);
    if (!getvar && result_reg != left) {
        self.emit_abc(Opcode.LDREG, (uint)left, (uint)result_reg, 0);
        self.free_reg(result_reg);
    }
    if (!getvar) {
        return { left, true, left };
    }
    if (void_ctx) {
        self.emit_var_store_op(store_op, left, t.name_idx, ref_reg);
        return { left, right.local, right.lreg };
    }
    ushort tmp = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
    self.emit_var_store_op(store_op, left, t.name_idx, ref_reg);
    self.free_reg(left);
    return { tmp, right.local, right.lreg };
}

// WITHGET retains the Reference that GetBindingValue reads; WITHBASE resolves without a read.
fn Val? CompilerContext.gen_with_assign(&self, uint n, uint name, TokenType op) {
    ast::Ast* tree = &ast::index_state.tree;
    bool plain = op == TokenType.ASSIGN;
    bool logical = op == TokenType.LOG_AND_ASSIGN || op == TokenType.LOG_OR_ASSIGN || op == TokenType.NULLISH_ASSIGN;
    ushort base = self.alloc_reg();
    ushort value = self.alloc_reg();
    ushort result = self.alloc_reg();
    if (plain) {
        self.emit_a_bc(Opcode.WITHBASE, (uint)base, name);
    } else {
        self.emit_abc(Opcode.WITHGET, (uint)value, (uint)base, name);
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)value, 0);
    }
    uint skip = uint::max;
    if (logical) {
        if (op == TokenType.NULLISH_ASSIGN) {
            ushort cmp = self.alloc_reg();
            self.emit_abc(Opcode.LDNULL, (uint)cmp, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp, (uint)value, (uint)cmp);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp);
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp, (uint)value, (uint)cmp);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp);
            self.free_reg(cmp);
            skip = self.emit_jump(Opcode.JUMP);
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);
        } else {
            skip = self.emit_cond_jump(op == TokenType.LOG_AND_ASSIGN ? Opcode.IF_FALSE : Opcode.IF_TRUE, (uint)value);
        }
    }
    NameEvalFrame names = self.save_name_eval();
    defer self.restore_name_eval(names);
    self.has_inferred_name = plain || logical;
    self.inferred_name = self.has_inferred_name ? self.gen_name(tree.lhs.data[tree.lhs.data[n]]) : "";
    Val right = self.gen_expr(tree.rhs.data[n], 0)!;
    self.gen_line_end(n);
    if (plain || logical) {
        self.emit_abc(Opcode.LDREG, (uint)value, (uint)right.reg, 0);
    } else {
        self.emit_abc(compound_assign_opcode(op), (uint)value, (uint)value, (uint)right.reg);
    }
    self.free_val(right);
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)value, 0);
    self.emit_abc(Opcode.WTWR, (uint)value, (uint)base, name);
    if (skip != uint::max) self.patch_jump(skip);
    return { result, false, 0 };
}

fn Val? CompilerContext.gen_logical_assign(&self, uint n, TokenType op) {
    ast::Ast* tree = &ast::index_state.tree;
    uint lhs = tree.lhs.data[n];
    bool member = tree.tags.data[lhs] != NodeTag.IDENT;
    MemberTarget mt;
    Target ident;
    ushort left;
    uint const_name = 0xFFFFFFFF;
    ushort reference = REG_NONE;
    NameEvalFrame names = self.save_name_eval();
    defer self.restore_name_eval(names);
    if (member) {
        mt = self.gen_member_target(lhs, tree.rhs.data[n])!;
        left = mt.value;
        self.has_inferred_name = false;
        self.inferred_name = {};
    } else {
        self.gen_line_main(lhs);
        char[] name = self.gen_name(tree.lhs.data[lhs]);
        ident = self.gen_target(name)!;
        left = ident.reg;
        if (ident.local) { const_name = self.find_const_name_idx(left); }
        else if (!(ident.global ? self.is_declared_global(ident.name_idx) : self.is_statically_resolvable_local(name))) {
            reference = self.alloc_reg();
            self.emit_a_bc(Opcode.RESOLVEVAR, (uint)reference, ident.name_idx);
        }
        self.has_inferred_name = (tree.flags.data[lhs] & ast::FLAG_PAREN) == 0;
        self.inferred_name = self.has_inferred_name ? name : "";
    }
    ushort result = left;
    if (member || !ident.local || const_name != 0xFFFFFFFF) {
        result = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)left, 0);
    }
    uint skip;
    if (op == TokenType.NULLISH_ASSIGN) {
        ushort cmp = self.alloc_reg();
        self.emit_abc(Opcode.LDNULL, (uint)cmp, 0, 0);
        self.emit_abc(Opcode.SEQ, (uint)cmp, (uint)left, (uint)cmp);
        uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp);
        self.emit_abc(Opcode.LDUNDEF, (uint)cmp, 0, 0);
        self.emit_abc(Opcode.SEQ, (uint)cmp, (uint)left, (uint)cmp);
        uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp);
        self.free_reg(cmp);
        skip = self.emit_jump(Opcode.JUMP);
        self.patch_jump(null_jump);
        self.patch_jump(undef_jump);
    } else {
        skip = self.emit_cond_jump(op == TokenType.LOG_AND_ASSIGN ? Opcode.IF_FALSE : Opcode.IF_TRUE,
            (uint)(member ? left : result));
    }
    Val right = self.gen_expr(tree.rhs.data[n], 0)!;
    self.gen_line_end(n);
    if (member) {
        self.emit_abc(mt.super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP, (uint)mt.base.reg, (uint)mt.key, (uint)right.reg);
        self.free_reg(mt.key);
        self.free_val(mt.base);
    }
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)right.reg, 0);
    self.free_val(right);
    if (!member && (!ident.local || const_name != 0xFFFFFFFF)) {
        if (!ident.local) self.emit_abc(Opcode.LDREG, (uint)left, (uint)result, 0);
        self.emit_var_store_op(ident.global ? Opcode.PUTGLOBAL : Opcode.PUTVAR_ASSIGN,
            ident.local ? result : left, ident.local ? const_name : ident.name_idx, reference);
    }
    self.patch_jump(skip);
    // A register-resident target remains the result's home on both branches.
    return { result, !member && ident.local && const_name == 0xFFFFFFFF, result };
}

fn Val CompilerContext.gen_const_store(&self, ushort reg, uint name_idx, bool discard) {
    ushort result = discard ? reg : self.alloc_reg();
    if (!discard) self.emit_abc(Opcode.LDREG, (uint)result, (uint)reg, 0);
    self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)reg, name_idx);
    if (!discard) self.free_reg(reg);
    return { result, false, 0 };
}

// `++x`, `--x`, `x++`, `x--`. A by-name read becomes the fused INC_VAR / DEC_VAR (or the global
// form) when the old value is not needed.
fn Val? CompilerContext.gen_update(&self, uint n, uint ctx) {
    ast::Ast* tree = &ast::index_state.tree;
    if (tree.tags.data[tree.lhs.data[n]] == NodeTag.CALL) return self.gen_invalid_call_target(tree.lhs.data[n]);
    if (tree.tags.data[tree.lhs.data[n]] != NodeTag.IDENT) return self.gen_member_update(n, ctx);
    bool post = tree.tags.data[n] == NodeTag.UPDATE_POST;
    bool inc = (TokenType)(tree.flags.data[n] & 0x7F) == TokenType.INC;
    char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[n]]);
    self.gen_line_main(tree.lhs.data[n]);
    if (self.in_with()) {
        uint name_idx = self.add_string_constant(name);
        ushort base = self.alloc_reg();
        ushort value = self.alloc_reg();
        self.emit_abc(Opcode.WITHGET, (uint)value, (uint)base, name_idx);
        bool materialise = post && (ctx & CTX_POSTFIX) == 0;
        ushort result = value;
        self.emit_abc(Opcode.TONUMERIC, (uint)value, (uint)value, 0);
        if (materialise) {
            result = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)result, (uint)value, 0);
        }
        self.gen_line_end(n);
        self.emit_a_bc(inc ? Opcode.INC : Opcode.DEC, (uint)value, 0);
        self.emit_abc(Opcode.WTWR, (uint)value, (uint)base, name_idx);
        return {result, false, 0};
    }
    Target t = self.gen_target(name)!;
    self.gen_line_end(n);
    ushort operand = t.reg;
    bool materialise = post && (ctx & CTX_POSTFIX) == 0;
    ushort saved = 0;
    if (materialise) {
        // ToNumeric of the old value (ES2020 §13.4.3.1): BigInt passes through.
        saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);
        self.emit_abc(Opcode.TONUMERIC, (uint)saved, (uint)saved, 0);
    }
    Opcode step = inc ? Opcode.INC : Opcode.DEC;
    if (t.local) {
        uint const_name = self.find_const_name_idx(operand);
        self.emit_a_bc(const_name != 0xFFFFFFFF ? (inc ? Opcode.INC_VAR : Opcode.DEC_VAR) : step,
            (uint)operand, const_name != 0xFFFFFFFF ? const_name : 0);
    } else if (materialise) {
        Opcode fused = t.global ? (inc ? Opcode.INC_GLOBAL : Opcode.DEC_GLOBAL) : (inc ? Opcode.INC_VAR : Opcode.DEC_VAR);
        self.emit_a_bc(fused, (uint)operand, t.name_idx);
        self.emit_abc(Opcode.NOP, 0, 0, 0);
    } else {
        Instruction last = self.code[self.code_count - 1];
        Opcode fused = t.global ? (inc ? Opcode.INC_GLOBAL : Opcode.DEC_GLOBAL) : (inc ? Opcode.INC_VAR : Opcode.DEC_VAR);
        self.code[self.code_count - 1] = bytecode::make_a_bc(fused, (uint)last.a, last.get_bc());
    }
    if (materialise) return { saved, t.local, operand };
    return { operand, t.local, operand };
}

// ---- member access and calls ----

// The reference must survive key evaluation and the RHS, including writes to a local base.
struct MemberTarget {
    Val base;
    ushort key;
    ushort value;
    uint key_const;
    Val markers;
    bool super;
    bool private;
}

// Children precede their parent: nodes after the base through the key/RHS contain every write
// that can change its home register. Captured bindings use the environment rather than a home.
// Long operands take a conservative copy to bound the cost of nested assignments.
fn bool CompilerContext.gen_writes_local(&self, uint first, uint last, ushort reg) {
    ast::Ast* tree = &ast::index_state.tree;
    for (uint i = first; i <= last; i++) {
        if (i - first == 64) return true;
        switch (tree.tags.data[i]) {
            case ASSIGN:
            case UPDATE_PRE:
            case UPDATE_POST:
                uint budget = 64;
                if (self.gen_target_writes_local(tree.lhs.data[i], reg, &budget)) return true;
            default:
                break;
        }
    }
    return false;
}

fn MemberTarget? CompilerContext.gen_member_target(&self, uint n, uint rhs = 0) {
    Phase ph = MEMBER;
    MemberTarget target;
    self.gen_chain(n, &ph, &target, rhs)!;
    // A store target does not supply the receiver of a call in its RHS.
    if (target.super) self.free_reg(self.call_prop_obj_reg);
    self.call_prop_obj_reg = REG_NONE;
    return target;
}

fn Val? CompilerContext.gen_member_assign(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    MemberTarget target = self.gen_member_target(tree.lhs.data[n], tree.rhs.data[n])!;
    if (op == TokenType.ASSIGN) self.gen_remove_member_read(target.super);
    NameEvalFrame frame = self.save_name_eval();
    defer self.restore_name_eval(frame);
    self.has_inferred_name = false;
    self.inferred_name = {};
    Val right = self.gen_expr(tree.rhs.data[n], 0)!;
    self.gen_line_end(n);
    if (op == TokenType.ASSIGN) {
        self.free_reg(target.value);
        self.emit_abc(target.super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP, (uint)target.base.reg, (uint)target.key, (uint)right.reg);
        self.free_reg(target.key);
        self.free_val(target.base);
        ushort result = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)right.reg, 0);
        if (!right.local) self.free_reg(right.reg);
        return { result, right.local, right.lreg };
    }
    self.emit_abc(compound_assign_opcode(op), (uint)target.value, (uint)target.value, (uint)right.reg);
    if (!right.local) self.free_reg(right.reg);
    self.emit_member_store(target.super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP, target.base.reg, target.key, target.value, target.key_const);
    self.free_reg(target.key);
    self.free_val(target.base);
    return { target.value, right.local, right.lreg };
}

fn Val? CompilerContext.gen_member_update(&self, uint n, uint ctx) {
    ast::Ast* tree = &ast::index_state.tree;
    MemberTarget target = self.gen_member_target(tree.lhs.data[n])!;
    self.gen_line_end(n);
    ushort result = target.value;
    bool materialise = tree.tags.data[n] == NodeTag.UPDATE_POST && (ctx & CTX_POSTFIX) == 0;
    if (materialise) {
        result = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)result, (uint)target.value, 0);
        self.emit_abc(Opcode.TONUMERIC, (uint)result, (uint)result, 0);
    }
    Opcode step = (TokenType)(tree.flags.data[n] & 0x7F) == TokenType.INC ? Opcode.INC : Opcode.DEC;
    self.emit_abc(step, (uint)target.value, 0, 0);
    self.emit_abc(target.super ? Opcode.PUTPROP_SUPER : Opcode.PUTPROP, (uint)target.base.reg, (uint)target.key, (uint)target.value);
    self.free_reg(target.key);
    self.free_val(target.base);
    return { result, target.markers.local, target.markers.lreg };
}

// Where a postfix chain stands: the leading run of `.name` / `[key]` steps, or after its first call.
// The two run different bookkeeping for the receiver a following call takes as `this`.
enum Phase : char {
    MEMBER,
    CALL,
}

fn bool is_chain_link(NodeTag t) {
    return t == NodeTag.MEMBER || t == NodeTag.INDEX || t == NodeTag.CALL
        || t == NodeTag.SUPER_MEMBER || t == NodeTag.SUPER_INDEX || t == NodeTag.PRIVATE_MEMBER;
}

fn Val? CompilerContext.gen_super(&self, uint n, MemberTarget* target) {
    ast::Ast* tree = &ast::index_state.tree;
    ushort base;
    ushort key;
    if (tree.tags.data[n] == NodeTag.SUPER_MEMBER) {
        self.gen_line_main(n);
        base = self.emit_super_base();
        self.gen_line_end(n);
        key = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)key, self.add_string_constant(tree.atoms.get(tree.rhs.data[n])));
    } else {
        // GetThisBinding precedes the computed key; a derived constructor can still be in TDZ.
        self.gen_line_main(n);
        ushort check = self.alloc_reg();
        self.emit_abc(Opcode.LDTHIS, (uint)check, 0, 0);
        self.free_reg(check);
        key = self.gen_expr(tree.rhs.data[n], 0)!.reg;
        self.gen_line_end(n);
        base = self.emit_super_base();
    }
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP_SUPER, (uint)result, (uint)base, (uint)key);
    if (target != null) *target = { { base, false, 0 }, key, result, self.member_key_const(key), {}, true, false };
    if (self.call_prop_obj_reg != REG_NONE) self.free_reg(self.call_prop_obj_reg);
    ushort receiver = self.alloc_reg();
    self.emit_abc(Opcode.LDTHIS, (uint)receiver, 0, 0);
    self.call_prop_obj_reg = receiver;
    return { result, false, 0 };
}

// A chain of member accesses and calls. `call_prop_obj_reg` holds the object of the last member
// step, the receiver of a call that follows it.
fn Val? CompilerContext.gen_chain(&self, uint n, Phase* ph, MemberTarget* target = null, uint rhs = 0, List{uint}* optional = null) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    NodeTag tag = tree.tags.data[n];
    uint obj = tree.lhs.data[n];
    if (tag == NodeTag.MEMBER && target == null && rhs == 0 && optional == null) {
        Val scalar;
        if (self.gen_scalar_new_member(n, &scalar)!) {
            *ph = Phase.MEMBER;
            return scalar;
        }
    }
    if (tag == NodeTag.CALL) return self.gen_call(n, ph, optional);
    if (tag == NodeTag.SUPER_MEMBER || tag == NodeTag.SUPER_INDEX) return self.gen_super(n, target);

    Val base;
    if (is_chain_link(tree.tags.data[obj])) {
        base = self.gen_chain(obj, ph, optional: optional)!;
    } else {
        *ph = Phase.MEMBER;
        base = self.gen_expr(obj, 0)!;
    }
    if ((tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0) {
        self.gen_line_main(n);
        self.gen_optional_test(base.reg, optional);
    }
    // Creating a closure does not execute its body.
    bool closure_rhs = rhs != 0 && (tree.tags.data[rhs] == NodeTag.FUNC_EXPR || tree.tags.data[rhs] == NodeTag.ARROW);
    if ((target != null || tag == NodeTag.INDEX) && base.local && base.reg == base.lreg
        && self.gen_writes_local(obj + 1, rhs != 0 && !closure_rhs ? rhs : n - 1, base.reg)) {
        self.gen_line_end(obj);
        ushort keep = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)keep, (uint)base.reg, 0);
        base.reg = keep;
    }
    ushort obj_reg = base.reg;
    ushort prop_reg;
    Val result;
    if (tag == NodeTag.PRIVATE_MEMBER) {
        self.gen_line_end(n);
        prop_reg = self.emit_private_access(self.gen_name(tree.rhs.data[n]), obj_reg)!;
        ushort dest = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP_PRIVATE, (uint)dest, (uint)obj_reg, (uint)prop_reg);
        result = { dest, base.local, base.lreg };
    } else if (tag == NodeTag.MEMBER) {
        self.gen_line_end(n);
        uint prop_const = self.add_string_constant(tree.atoms.get(tree.rhs.data[n]));
        prop_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const);
        ushort dest = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)dest, (uint)obj_reg, (uint)prop_reg);
        if (*ph == Phase.MEMBER && target == null) self.free_reg(prop_reg);
        result = { dest, base.local, base.lreg };
    } else {
        Val key = self.gen_expr(tree.rhs.data[n], 0)!;
        self.gen_line_end(n);
        prop_reg = self.shield_computed_key(key.reg);
        ushort dest = self.alloc_reg();
        self.emit_abc((tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0 ? Opcode.GETPROP : Opcode.GETPROP_CACHE,
            (uint)dest, (uint)obj_reg, (uint)prop_reg);
        if (*ph == Phase.MEMBER && target == null) self.free_reg(prop_reg);
        result = { dest, key.local, key.lreg };
    }
    if (target != null) {
        *target = { base, prop_reg, result.reg, self.member_key_const(prop_reg), result, false, tag == NodeTag.PRIVATE_MEMBER };
    }
    if (*ph == Phase.MEMBER && self.call_prop_obj_reg != REG_NONE) self.free_reg(self.call_prop_obj_reg);
    self.call_prop_obj_reg = obj_reg;
    return result;
}

// ---- calls ----

// `callee(args)`. The frame is the callee at `callee_reg`, the receiver slot after it, then the
// arguments in consecutive registers; the result replaces the callee. A by-name callee read
// fuses into CALL_VAR / CALL_GLOBAL, which loads and calls at once; a member callee passes the
// pending receiver as `this`.
fn Val? CompilerContext.gen_call(&self, uint n, Phase* ph, List{uint}* optional = null) {
    ast::Ast* tree = &ast::index_state.tree;
    uint callee_node = tree.lhs.data[n];
    uint args = tree.rhs.data[n];
    if (try v = self.gen_regexp_test(n)) {
        *ph = Phase.CALL;
        return v;
    }

    ushort callee_reg;
    bool fusable = false;
    bool global = false;
    uint name_idx = 0;
    uint getvar_code_pos = 0;
    if (tree.tags.data[callee_node] == NodeTag.IDENT) {
        *ph = Phase.MEMBER;
        self.gen_line_main(callee_node);
        Target t = self.gen_target(self.gen_name(tree.lhs.data[callee_node]))!;
        callee_reg = t.reg;
        if (self.in_with() && !t.local) {
            self.code_count--;
            if (self.code_count > 0 && self.code[self.code_count - 1].op == Opcode.WIDE) self.code_count--;
            ushort receiver = self.alloc_reg();
            self.emit_abc(Opcode.WITHGET, (uint)callee_reg, (uint)receiver, t.name_idx);
            self.call_prop_obj_reg = receiver;
        }
        global = t.global;
        name_idx = t.name_idx;
        fusable = (tree.flags.data[n] & ast::FLAG_OPTIONAL) == 0 && !t.local && self.code_count > 0 && t.name_idx <= bytecode::MAX_C
            && self.code[self.code_count - 1].op == (t.global ? Opcode.GETGLOBAL : Opcode.GETVAR)
            && self.code[self.code_count - 1].a == callee_reg
            && self.call_prop_obj_reg == REG_NONE;
        getvar_code_pos = self.code_count - 1;
    } else {
        Val callee;
        if (is_chain_link(tree.tags.data[callee_node])) {
            callee = self.gen_chain(callee_node, ph, optional: optional)!;
        } else {
            // A call on a freshly constructed object has no receiver.
            callee = self.gen_expr(callee_node, 0)!;
            if (tree.tags.data[callee_node] != NodeTag.OPT_CHAIN) self.call_prop_obj_reg = REG_NONE;
        }
        callee_reg = callee.reg;
    }
    bool direct_eval = tree.tags.data[callee_node] == NodeTag.IDENT
        && tree.atoms.get(tree.lhs.data[callee_node]) == "eval"
        && (tree.flags.data[n] & ast::FLAG_OPTIONAL) == 0;
    if (direct_eval) self.has_direct_eval = true;
    if ((tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0) {
        self.gen_line_main(n);
        self.gen_optional_test(callee_reg, optional);
    }
    // A fused by-name call reads its callee after the arguments. Keep the earlier value when
    // an argument can change the binding, including through another call.
    if (fusable && !self.gen_call_args_stable(callee_node + 1, n - 1)) fusable = false;
    *ph = Phase.CALL;
    self.gen_line_end(callee_node);
    ushort first_arg = callee_reg + 2;

    // A callee that sits below live registers, or is a local's home register, is copied above
    // them: the call writes its result over the callee slot.
    if (callee_reg + 1 < self.next_reg || self.is_local_var_reg(callee_reg)) {
        fusable = false;
        ushort moved = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)moved, (uint)callee_reg, 0);
        callee_reg = moved;
        first_arg = callee_reg + 2;
        if (self.next_reg <= callee_reg + 1) self.next_reg = callee_reg + 2;
    } else if (fusable) {
        self.code_count = getvar_code_pos;
    }
    // A receiver is copied into the slot after the callee; otherwise the slot is reserved, not
    // written, and the VM supplies undefined.
    bool undef_this = self.call_prop_obj_reg == REG_NONE;
    if (!undef_this) {
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)self.call_prop_obj_reg, 0);
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    } else if (self.next_reg <= callee_reg + 1) {
        self.next_reg = callee_reg + 2;
    }
    if (self.next_reg < first_arg) self.next_reg = first_arg;

    Val last_arg;
    ushort spread = REG_NONE;
    ushort arg_count = self.gen_args(args, &callee_reg, &last_arg, &spread)!;

    self.gen_line_end(n);
    Opcode opcode;
    uint operand_b;
    uint operand_c;
    if (spread != REG_NONE) {
        if (undef_this) self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
        if (fusable) self.emit_a_bc(global ? Opcode.GETGLOBAL : Opcode.GETVAR, (uint)callee_reg, name_idx);
        opcode = Opcode.CALL_S;
        operand_b = callee_reg;
        operand_c = spread;
    } else if (undef_this && fusable) {
        opcode = global ? Opcode.CALL_GLOBAL : Opcode.CALL_VAR;
        operand_b = arg_count;
        operand_c = name_idx;
    } else {
        opcode = undef_this ? Opcode.CALL_UNDEF_THIS : Opcode.CALL;
        operand_b = callee_reg;
        operand_c = arg_count;
    }
    if (direct_eval) self.direct_eval_offsets.push(self.code_count);
    self.emit_abc(opcode, (uint)callee_reg, operand_b, operand_c);
    self.free_regs_to(callee_reg);
    self.next_reg = callee_reg + 1;
    if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    // An argument's member access can leave a receiver pending; the call result has none.
    if (self.call_prop_obj_reg != REG_NONE) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }
    return { callee_reg, false, 0 };
}

// `/lit/.test(x)` with no g or y flag never exposes its RegExp, so RETEST
// matches without creating one. Faults when the call has another shape.
faultdef NOT_REGEXP_TEST;
fn Val? CompilerContext.gen_regexp_test(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint callee = tree.lhs.data[n];
    uint args = tree.rhs.data[n];
    if (g_disable_optimize || (tree.flags.data[n] & ast::FLAG_OPTIONAL) != 0
        || tree.tags.data[callee] != NodeTag.MEMBER || (tree.flags.data[callee] & ast::FLAG_OPTIONAL) != 0
        || tree.atoms.get(tree.rhs.data[callee]) != "test") return NOT_REGEXP_TEST~;
    uint lit = tree.lhs.data[callee];
    if (tree.tags.data[lit] != NodeTag.REGEX || tree.list_len(args) != 1
        || tree.tags.data[tree.list_item(args, 0)] == NodeTag.SPREAD) return NOT_REGEXP_TEST~;
    char[] text = tree.atoms.get(tree.lhs.data[lit]);
    for (usz i = text.len; i > 0 && text[i - 1] != '/'; i--) {
        if (text[i - 1] == 'g' || text[i - 1] == 'y') return NOT_REGEXP_TEST~;
    }
    uint k = self.add_string_constant(text);
    if (k > bytecode::MAX_C) return NOT_REGEXP_TEST~;
    self.gen_line_main(n);
    ushort dst = self.alloc_reg();
    Val arg = self.gen_expr(tree.list_item(args, 0), 0)!;
    self.gen_line_end(n);
    self.emit_abc(Opcode.RETEST, (uint)dst, (uint)arg.reg, k);
    self.free_regs_to(dst + 1);
    return { dst, false, 0 };
}

// ---- unary operators ----

fn Val? CompilerContext.gen_unary(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    uint operand = tree.lhs.data[n];
    if (op == TokenType.TYPEOF) return self.gen_typeof(operand);
    if (op == TokenType.DELETE) return self.gen_delete(operand);
    Opcode code;
    switch (op) {
        case MINUS: code = UNM;
        case PLUS: code = UNP;
        case LOG_NOT: code = LNOT;
        case BIT_NOT: code = BNOT;
        default: code = VOID;
    }
    Val v = self.gen_expr(operand, 0)!;
    self.gen_line_end(n);
    ushort result = self.alloc_reg();
    self.emit_abc(code, (uint)result, (uint)v.reg, 0);
    self.free_reg(v.reg);
    return { result, false, 0 };
}

// `typeof name` reads a register-resident local directly and everything else by name, where an
// unresolvable reference yields "undefined" rather than a ReferenceError (ES5 §11.4.3).
fn Val? CompilerContext.gen_typeof(&self, uint operand) {
    ast::Ast* tree = &ast::index_state.tree;
    if (tree.tags.data[operand] == NodeTag.IDENT) {
        char[] name = self.gen_name(tree.lhs.data[operand]);
        if (!str_eq(name, "undefined")) {
            self.gen_line_main(operand);
            if (try res = self.try_emit_typeof_register(name)) return { res, false, 0 };
            self.note_arguments_reference(name)!;
            uint name_idx = self.add_string_constant(name);
            ushort res = self.alloc_reg();
            self.emit_a_bc(Opcode.TYPEOFIDENT, (uint)res, name_idx);
            return { res, false, 0 };
        }
    }
    if (tree.tags.data[operand] == NodeTag.MEMBER || tree.tags.data[operand] == NodeTag.INDEX
        || tree.tags.data[operand] == NodeTag.SUPER_MEMBER || tree.tags.data[operand] == NodeTag.SUPER_INDEX) {
        MemberTarget target = self.gen_member_target(operand)!;
        bool local_base = target.base.local && target.base.reg == target.base.lreg;
        ushort result = local_base ? target.value : target.base.reg;
        self.emit_abc(Opcode.TYPEOF, (uint)result, (uint)target.value, 0);
        if (!local_base) {
            self.free_reg(target.value);
            self.free_reg(target.key);
        }
        return { result, false, 0 };
    }
    Val v = self.gen_expr(operand, 0)!;
    self.gen_line_end(operand);
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.TYPEOF, (uint)result, (uint)v.reg, 0);
    self.free_reg(v.reg);
    return { result, false, 0 };
}

fn Val? CompilerContext.gen_delete(&self, uint operand) {
    ast::Ast* tree = &ast::index_state.tree;
    NodeTag tag = tree.tags.data[operand];
    if (tag == NodeTag.OPT_CHAIN) return self.gen_optional_chain(operand, true);
    if (tag == NodeTag.SUPER_MEMBER || tag == NodeTag.SUPER_INDEX) {
        self.gen_line_main(operand);
        if (tag == NodeTag.SUPER_INDEX) {
            ushort check = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)check, 0, 0);
            self.free_reg(check);
            self.free_val(self.gen_expr(tree.rhs.data[operand], 0)!);
        }
        self.gen_line_end(operand);
        ushort result = self.alloc_reg();
        self.emit_a_bc(Opcode.THROW_REF, (uint)result, self.add_string_constant("Cannot delete a super property"));
        self.call_prop_obj_reg = REG_NONE;
        result = self.alloc_reg();
        self.emit_abc(Opcode.LDTRUE, (uint)result, 0, 0);
        return { result, false, 0 };
    }
    if (tag == NodeTag.MEMBER || tag == NodeTag.INDEX) {
        MemberTarget target = self.gen_member_target(operand)!;
        Instruction read = self.code[self.code_count - 1];
        self.code[self.code_count - 1] = bytecode::make_abc(Opcode.DELPROP, read.a, read.b, read.c);
        self.free_reg(target.key);
        self.free_val(target.base);
        return { target.value, false, 0 };
    }
    Val v = self.gen_expr(operand, 0)!;
    self.gen_line_end(operand);
    ushort result = self.alloc_reg();
    if (tag == NodeTag.IDENT) {
        if (v.local) {
            self.emit_abc(Opcode.LDFALSE, (uint)result, 0, 0);
        } else {
            Instruction read = self.code[self.code_count - 1];
            self.emit_a_bc(Opcode.DELVAR, (uint)result, read.get_bc());
            // Delete resolves the binding itself; the load must not throw for an absent name.
            self.code[self.code_count - 2] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
    } else {
        self.emit_abc(Opcode.LDTRUE, (uint)result, 0, 0);
    }
    return { result, false, 0 };
}

// Each argument is evaluated into the register after the previous one, from `first_arg`.
fn ushort? CompilerContext.gen_args(&self, uint args, ushort* callee, Val* last, ushort* spread) {
    ast::Ast* tree = &ast::index_state.tree;
    ushort first_arg = *callee + 2;
    ushort outer_spread_base = self.spread_eval_base;
    defer self.spread_eval_base = outer_spread_base;
    ushort count = 0;
    for (uint i = 0; i < tree.list_len(args); i++) {
        uint a = tree.list_item(args, i);
        bool is_spread = tree.tags.data[a] == NodeTag.SPREAD;
        bool first_spread = is_spread && *spread == REG_NONE;
        if (first_spread) {
            self.gen_line_main(a);
            *spread = self.begin_spread_args(callee, &first_arg, count);
            self.emit_a_sbx(Opcode.LDINT, (uint)*spread, (int)count);
        }
        Val arg;
        {
            ushort saved_cap = self.reg_cap;
            defer self.reg_cap = saved_cap;
            if (*spread != REG_NONE && !first_spread) {
                self.next_reg = self.spread_eval_base;
                self.reg_cap = *callee;
            }
            arg = self.gen_expr(is_spread ? tree.lhs.data[a] : a, 0)!;
        }
        *last = arg;
        self.gen_line_end(a);
        if (is_spread) {
            ushort source = arg.reg;
            if (first_spread && source >= first_arg + count && source <= first_arg + count + 10) {
                ushort keep = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)keep, (uint)source, 0);
                self.free_reg(source);
                source = keep;
            }
            self.emit_abc(Opcode.SPREAD_ARG, (uint)first_arg, (uint)*spread, (uint)source);
            self.free_reg(source);
            continue;
        }
        if (*spread != REG_NONE) {
            self.emit_abc(Opcode.PUTARG, (uint)first_arg, (uint)*spread, (uint)arg.reg);
            self.free_reg(arg.reg);
            continue;
        }
        ushort expected = first_arg + count;
        if (arg.reg != expected) {
            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg.reg, 0);
            self.free_reg(arg.reg);
            if (self.next_reg <= expected) self.next_reg = expected + 1;
        }
        count++;
    }
    return count;
}

// `new callee(args)`. The constructor is copied to a fresh register before the arguments run
// (ES2023 §13.3.1.1: GetValue(constructor) precedes argument evaluation), so an argument that
// assigns to a local holding the constructor cannot change which function is constructed.
fn Val? CompilerContext.gen_new(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    Val callee = self.gen_expr(tree.lhs.data[n], 0)!;
    // The constructor's own receiver is not the `this` of any call in the arguments.
    if (self.call_prop_obj_reg != REG_NONE) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }
    self.gen_line_end(tree.lhs.data[n]);
    ushort ctor = self.alloc_reg();
    if (ctor != callee.reg) self.emit_abc(Opcode.LDREG, (uint)ctor, (uint)callee.reg, 0);
    ushort first_arg = ctor + 2;
    if (self.next_reg < first_arg) self.next_reg = first_arg;
    Val last = callee;
    ushort spread = REG_NONE;
    ushort arg_count = self.gen_args(tree.rhs.data[n], &ctor, &last, &spread)!;
    self.gen_line_end(n);
    self.emit_abc(spread != REG_NONE ? Opcode.NEW_OBJ_S : Opcode.NEW_OBJ,
        (uint)ctor, (uint)ctor, (uint)(spread != REG_NONE ? spread : arg_count));
    self.free_regs_to(ctor);
    self.next_reg = ctor + 1;
    if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    // `new` leaves the reference markers of its last operand in place.
    return { ctor, last.local, last.lreg };
}

// ---- array literals ----

// `[a, , ...b]`. Elements are stored at compile-time indices until a spread makes the next index
// a runtime value, which then lives in a register.
fn Val? CompilerContext.gen_array(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint elems = tree.lhs.data[n];
    self.has_inferred_name = false;
    self.inferred_name = {};
    self.gen_line_main(n);
    ushort arr_reg = self.alloc_reg();
    uint newarr_pc = self.emit_a_bc(Opcode.NEWARR, (uint)arr_reg, 0);
    uint index = 0;
    ushort idx_reg = REG_NONE;
    bool has_spread = false;
    bool has_dense_value = false;
    uint init_len = 0;
    for (uint i = 0; i < tree.list_len(elems); i++) {
        uint e = tree.list_item(elems, i);
        if (e == 0) {
            if (has_spread) {
                self.gen_index_step(idx_reg);
            } else {
                index++;
            }
        } else if (tree.tags.data[e] == NodeTag.SPREAD) {
            Val src = self.gen_expr(tree.lhs.data[e], 0)!;
            self.gen_line_end(e);
            if (!has_spread) {
                has_spread = true;
                idx_reg = self.alloc_reg();
                self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index);
            }
            self.emit_abc(Opcode.ARRSPRD, (uint)arr_reg, (uint)idx_reg, (uint)src.reg);
            self.free_reg(src.reg);
        } else {
            Val elem = self.gen_expr(e, 0)!;
            self.gen_line_end(e);
            has_dense_value = true;
            // INITELEM / INITPROP define the element, so a non-writable prototype index cannot block it.
            if (has_spread) {
                self.emit_abc(Opcode.INITPROP, (uint)arr_reg, (uint)idx_reg, (uint)elem.reg);
                self.gen_index_step(idx_reg);
            } else if (index <= 0xFF) {
                self.emit_abc(Opcode.INITELEM, (uint)arr_reg, index, (uint)elem.reg);
                index++;
                init_len = index;
            } else {
                ushort idx_const = self.alloc_reg();
                self.emit_a_sbx(Opcode.LDINT, (uint)idx_const, (int)index);
                self.emit_abc(Opcode.INITPROP, (uint)arr_reg, (uint)idx_const, (uint)elem.reg);
                self.free_reg(idx_const);
                index++;
            }
            self.free_reg(elem.reg);
        }
    }
    if (has_spread) {
        uint len_const = self.add_string_constant("length");
        ushort len_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)len_reg, len_const);
        self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)len_reg, (uint)idx_reg);
        self.free_reg(len_reg);
    } else {
        // A short literal reserves its final dense length at NEWARR instead of the default part.
        if (has_dense_value && index > 0 && index < hobject::ARRAY_INITIAL_SIZE) {
            self.code[newarr_pc] = bytecode::make_a_bc(Opcode.NEWARR, (uint)arr_reg, index);
        }
        if (index != init_len) self.emit_a_bc(Opcode.SETALEN, (uint)arr_reg, index);
    }
    return { arr_reg, false, 0 };
}

fn void CompilerContext.gen_index_step(&self, ushort idx_reg) {
    ushort one = self.alloc_reg();
    self.emit_a_sbx(Opcode.LDINT, (uint)one, 1);
    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
    self.free_reg(one);
}

// ---- object literals ----

// `{ key: value, [computed]: value, shorthand, ...spread }`. A literal whose properties are all
// plain data properties under distinct static keys is given a fixed shape afterwards.
fn Val? CompilerContext.gen_object(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint props = tree.lhs.data[n];
    self.has_inferred_name = false;
    self.inferred_name = {};
    self.gen_line_main(n);
    ushort obj_reg = self.alloc_reg();
    uint new_pc = self.code_count;
    self.emit_abc(Opcode.NEWOBJ, (uint)obj_reg, 0, 0);
    List{LiteralSlot} slots;
    slots.init(mem);
    defer slots.free();
    bool fixed_shape = !self.disable_optimize;
    bool seen_proto_key = false;
    uint home = 0xFFFFFFFF;
    for (uint i = 0; i < tree.list_len(props); i++) {
        uint p = tree.list_item(props, i);
        NameEvalFrame frame = self.save_name_eval();
        defer self.restore_name_eval(frame);
        switch (tree.tags.data[p]) {
            case PROP_SPREAD:
                fixed_shape = false;
                Val src = self.gen_expr(tree.lhs.data[p], 0)!;
                self.gen_line_end(p);
                self.emit_abc(Opcode.OBJSPRD, (uint)obj_reg, 0, (uint)src.reg);
                self.free_reg(src.reg);
            case PROP_SHORTHAND:
                self.gen_line_main(p);
                char[] name = self.gen_name(tree.lhs.data[tree.lhs.data[p]]);
                uint name_idx = self.add_string_constant(name);
                uint key_pc = self.code_count;
                ushort key_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, name_idx);
                if (try val_reg = self.resolve_var(name)) {
                    slots.push({name_idx, key_pc, self.code_count});
                    self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                } else {
                    ushort val_reg = self.alloc_reg();
                    self.emit_ident_read((uint)val_reg, name_idx)!;
                    slots.push({name_idx, key_pc, self.code_count});
                    self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                    self.free_reg(val_reg);
                }
                self.free_reg(key_reg);
            default:
                self.gen_init_property(p, obj_reg, &slots, &fixed_shape, &seen_proto_key, &home)!;
        }
    }
    self.gen_line_end(n);
    if (fixed_shape) self.specialize_object_literal(new_pc, slots.array_view());
    if (home != 0xFFFFFFFF) self.emit_simple(Opcode.POP_LEX);
    return { obj_reg, false, 0 };
}

// `key: value`. A static `__proto__` key sets the prototype instead of defining a property. A
// computed key is coerced before the value runs (ES2015 §12.2.6.7).
fn void? CompilerContext.gen_init_property(&self, uint p, ushort obj_reg, List{LiteralSlot}* slots, bool* fixed_shape, bool* seen_proto_key, uint* home) {
    ast::Ast* tree = &ast::index_state.tree;
    uint key_node = tree.lhs.data[p];
    uint value = tree.rhs.data[p];
    bool computed = (tree.flags.data[p] & ast::PROP_COMPUTED) != 0;
    bool method = tree.tags.data[p] != NodeTag.PROP_INIT;
    ushort key_reg;
    uint literal_key = uint::max;
    uint literal_key_pc = 0;
    bool is_proto_key = false;
    if (computed) {
        self.has_inferred_name = false;
        self.inferred_name = {};
        Val k = self.gen_expr(key_node, 0)!;
        self.gen_line_end(key_node);
        key_reg = self.shield_computed_key(k.reg);
        self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
    } else if (tree.tags.data[key_node] == NodeTag.STRING) {
        self.gen_line_main(key_node);
        char[] key = tree.atoms.get(tree.lhs.data[key_node]);
        is_proto_key = !method && str_eq(key, "__proto__");
        literal_key = self.add_string_constant(key);
        literal_key_pc = self.code_count;
        key_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, literal_key);
        self.has_inferred_name = true;
        self.inferred_name = key;
    } else {
        bool bigint = tree.tags.data[key_node] == NodeTag.BIGINT;
        ulong bits = ((ulong)tree.rhs.data[key_node] << 32) | (ulong)tree.lhs.data[key_node];
        if (bigint) {
            key_reg = self.gen_expr(key_node, 0)!.reg;
        } else {
            self.gen_line_main(key_node);
            key_reg = self.alloc_reg();
            self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, self.add_number_constant(bitcast(bits, double)));
        }
        char[] text = bigint ? tree.atoms.get(tree.lhs.data[key_node]) : "";
        if (bigint) self.emit_abc(Opcode.TOPROPKEY, (uint)key_reg, 0, 0);
        self.set_numeric_inferred_name({}, !bigint, bigint ? 0.0 : bitcast(bits, double), bigint, text)!;
        *fixed_shape = false;
    }
    if (is_proto_key) {
        *fixed_shape = false;
        if (*seen_proto_key && self.is_strict) return COMPILE_ERROR~;
        *seen_proto_key = true;
        self.has_inferred_name = false;
        self.inferred_name = {};
    } else if (computed) {
        // The flag stays set unless the value is an anonymous function definition, which consumes it.
        self.has_inferred_name = true;
        self.inferred_name = {};
    }
    if (method && *home == 0xFFFFFFFF) {
        self.emit_simple(Opcode.PUSH_LEX);
        ushort reg = self.declare_var("__super__", LET);
        *home = self.add_string_constant("__super__");
        self.emit_abc(Opcode.LDREG, (uint)reg, (uint)obj_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)reg, *home);
    }
    Val v;
    if (method) {
        *fixed_shape = false;
        @pool() {
            if (!computed && (tree.tags.data[p] == NodeTag.PROP_GET || tree.tags.data[p] == NodeTag.PROP_SET)) {
                self.inferred_name = (char[])string::tformat("%s %s",
                    tree.tags.data[p] == NodeTag.PROP_GET ? "get" : "set", (String)self.inferred_name);
            }
            v = self.gen_closure(value, *home)!;
        };
    } else {
        v = self.gen_expr(value, 0)!;
    }
    self.gen_line_end(value);
    bool anonymous_fn_value = computed && !is_proto_key && !self.has_inferred_name;
    if (tree.tags.data[p] == NodeTag.PROP_GET || tree.tags.data[p] == NodeTag.PROP_SET) {
        self.emit_abc(tree.tags.data[p] == NodeTag.PROP_GET ? Opcode.INITGET : Opcode.INITSET,
            (uint)obj_reg, (uint)key_reg, (uint)v.reg);
    } else if (is_proto_key) {
        self.emit_abc(Opcode.SETPROTO, (uint)obj_reg, (uint)v.reg, 0);
    } else if (anonymous_fn_value) {
        *fixed_shape = false;
        self.emit_abc(Opcode.INITPROPN, (uint)obj_reg, (uint)key_reg, (uint)v.reg);
    } else {
        slots.push({literal_key, literal_key_pc, self.code_count});
        self.emit_abc(Opcode.INITPROP, (uint)obj_reg, (uint)key_reg, (uint)v.reg);
    }
    self.free_reg(v.reg);
    self.free_reg(key_reg);
}
// Flatten AST patterns into the shared destructuring emitter's extraction records.
fn void? CompilerContext.gen_collect_pattern(&self, uint n, DestructBinds* binds,
    ushort source = 0, ushort parent = 0xFFFF) {
    self.check_stack()!;
    ast::Ast* tree = &ast::index_state.tree;
    bool object = tree.tags.data[n] == NodeTag.OBJECT_PAT;
    uint items = tree.lhs.data[n];
    uint count = tree.list_len(items);
    if (!object && count == 0) {
        self.add_bind(binds, { .arg_idx = source, .parent_idx = parent,
            .is_synthetic = true, .is_empty_pattern = true })!;
    }
    for (uint i = 0; i < count; i++) {
        uint item = tree.list_item(items, i);
        uint target = item;
        uint default_expr = 0;
        DestructBind b = { .arg_idx = source, .parent_idx = parent,
            .is_object = object, .index = (ushort)i };
        if (item == 0) {
            b.is_synthetic = true;
            b.is_hole = true;
        } else {
            if (tree.tags.data[item] == NodeTag.REST) {
                b.key_idx = 0xFFFF;
                target = tree.lhs.data[item];
            } else if (object) {
                uint key = tree.lhs.data[item];
                if ((tree.flags.data[item] & ast::PROP_COMPUTED) != 0) {
                    b.is_computed_key = true;
                    b.ast_key = key;
                } else {
                    b.key_idx = self.gen_pattern_key(key)!;
                }
                if ((tree.flags.data[item] & ast::PROP_SHORTHAND_PAT) != 0) {
                    target = key;
                    default_expr = tree.rhs.data[item];
                } else {
                    target = tree.rhs.data[item];
                }
            }
            if (tree.tags.data[target] == NodeTag.ASSIGN_PAT) {
                default_expr = tree.rhs.data[target];
                target = tree.lhs.data[target];
            }
            NodeTag tag = tree.tags.data[target];
            b.is_synthetic = tag == NodeTag.ARRAY_PAT || tag == NodeTag.OBJECT_PAT;
            if (!b.is_synthetic) {
                b.is_member_target = tag != NodeTag.IDENT;
                if (b.is_member_target) {
                    b.ast_target = target;
                } else {
                    b.name_idx = self.add_string_constant(self.gen_name(tree.lhs.data[target]));
                }
            }
        }
        ushort index = self.add_bind(binds, b)!;
        if (b.is_synthetic && !b.is_hole) self.gen_collect_pattern(target, binds, source, index)!;
        if (default_expr != 0) {
            DestructBind* bind = binds.get_ref(index);
            bind.has_default = true;
            bind.ast_default = default_expr;
        }
    }
}

fn uint? CompilerContext.gen_pattern_key(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    if (tree.tags.data[n] == NodeTag.IDENT || tree.tags.data[n] == NodeTag.STRING) {
        return self.add_string_constant(tree.atoms.get(tree.lhs.data[n]));
    }
    NameEvalFrame frame = self.save_name_eval();
    defer self.restore_name_eval(frame);
    bool bigint = tree.tags.data[n] == NodeTag.BIGINT;
    ulong bits = ((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n];
    self.set_numeric_inferred_name({}, !bigint, bigint ? 0.0 : bitcast(bits, double), bigint,
        bigint ? tree.atoms.get(tree.lhs.data[n]) : "")!;
    return self.add_string_constant(self.inferred_name);
}

fn void CompilerContext.gen_tdz_pattern(&self, uint n, uint outer_depth) {
    if (n == 0) return;
    ast::Ast* tree = &ast::index_state.tree;
    switch (tree.tags.data[n]) {
        case IDENT:
            char[] name = self.gen_name(tree.lhs.data[n]);
            self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(name));
            for (uint k = 0; k < outer_depth; k++) {
                if (str_eq(self.scope_stack[k].name, name)) {
                    self.mark_scope_captured(k);
                    break;
                }
            }
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint items = tree.lhs.data[n];
            for (uint i = 0; i < tree.list_len(items); i++) self.gen_tdz_pattern(tree.list_item(items, i), outer_depth);
        case PAT_PROP:
            self.gen_tdz_pattern((tree.flags.data[n] & ast::PROP_SHORTHAND_PAT) != 0
                ? tree.lhs.data[n] : tree.rhs.data[n], outer_depth);
        case ASSIGN_PAT:
        case REST:
            self.gen_tdz_pattern(tree.lhs.data[n], outer_depth);
        default:
            break;
    }
}

fn void CompilerContext.gen_declare_pattern(&self, DestructBind[] binds, ScopeKind kind, bool parameter = false) {
    foreach (&b : binds) {
        if (!b.is_synthetic) b.binding_reg = parameter
            ? self.declare_var(self.bind_name(b), kind, true) : self.declare_binding_var(self.bind_name(b), kind);
    }
}

fn void? CompilerContext.gen_destruct_decl(&self, uint pattern, uint init, ScopeKind kind) {
    DestructBinds binds = { .allocator = mem };
    defer free_destruct_binds(&binds);
    self.gen_collect_pattern(pattern, &binds)!;
    self.gen_declare_pattern(binds.array_view(), kind);
    if (self.gen_scalar_object_pattern(init, binds.array_view(), kind)!) return;
    if (self.gen_scalar_array_pattern(init, binds.array_view(), kind)!) return;
    ushort floor = self.next_reg;
    Val value = self.gen_expr(init, 0)!;
    self.gen_line_end(init);
    self.emit_destructure(binds.array_view(), ast::index_state.tree.tags.data[pattern] == NodeTag.OBJECT_PAT,
        value.reg, DECLARE, kind != VAR, kind == CONST)!;
    self.free_regs_to(floor);
}

// A fresh literal cannot escape before its values are evaluated. When every
// requested key is an own data property, keep those values in registers and
// initialize bindings only after the entire literal has run.
fn bool? CompilerContext.gen_scalar_object_pattern(&self, uint init,
    DestructBind[] binds, ScopeKind kind) {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.disable_optimize || kind == VAR || self.in_with()
        || tree.tags.data[init] != NodeTag.OBJECT) return false;
    uint props = tree.lhs.data[init];
    uint count = tree.list_len(props);
    // Bound temporary register pressure; larger literals keep object storage.
    if (count > 64) return false;
    uint[64] keys;
    ushort[64] values;
    for (uint i = 0; i < count; i++) {
        uint prop = tree.list_item(props, i);
        uint key = tree.lhs.data[prop];
        if (tree.tags.data[prop] != NodeTag.PROP_INIT
            || (tree.flags.data[prop] & ast::PROP_COMPUTED) != 0
            || tree.tags.data[key] != NodeTag.STRING) return false;
        char[] name = tree.atoms.get(tree.lhs.data[key]);
        if (str_eq(name, "__proto__")) return false;
        keys[i] = self.add_string_constant(name);
    }
    foreach (bind : binds) {
        if (!bind.is_object || bind.is_synthetic || bind.is_member_target
            || bind.is_computed_key || bind.has_default || bind.key_idx == 0xFFFF
            || bind.parent_idx != 0xFFFF) return false;
        bool found = false;
        for (uint i = 0; i < count; i++) found |= keys[i] == bind.key_idx;
        if (!found) return false;
    }

    self.has_inferred_name = false;
    self.inferred_name = {};
    self.gen_line_main(init);
    ushort floor = self.next_reg;
    defer self.free_regs_to(floor);
    for (uint i = 0; i < count; i++) values[i] = self.alloc_persistent_reg();
    ushort eval_floor = self.next_reg;
    for (uint i = 0; i < count; i++) {
        uint prop = tree.list_item(props, i);
        NameEvalFrame frame = self.save_name_eval();
        defer self.restore_name_eval(frame);
        self.has_inferred_name = true;
        self.inferred_name = tree.atoms.get(tree.lhs.data[tree.lhs.data[prop]]);
        Val value = self.gen_expr(tree.rhs.data[prop], 0)!;
        self.emit_abc(Opcode.LDREG, values[i], value.reg, 0);
        self.free_regs_to(eval_floor);
    }
    self.gen_line_end(init);
    foreach (bind : binds) {
        uint selected = 0;
        for (uint i = 0; i < count; i++) {
            if (keys[i] == bind.key_idx) selected = i;
        }
        self.emit_abc(Opcode.LDREG, bind.binding_reg, values[selected], 0);
        self.emit_var_store(bind.binding_reg, bind.name_idx, true, kind == CONST);
    }
    return true;
}

fn bool? CompilerContext.gen_scalar_array_pattern(&self, uint init,
    DestructBind[] binds, ScopeKind kind) {
    ast::Ast* tree = &ast::index_state.tree;
    if (self.disable_optimize || kind == VAR || tree.tags.data[init] != NodeTag.ARRAY
        || !self.can_fast_flat_array(binds, false, false)) return false;
    uint elems = tree.lhs.data[init];
    uint count = tree.list_len(elems);
    if (count < binds.len || count > 64) return false;
    for (uint i = 0; i < count; i++) {
        uint elem = tree.list_item(elems, i);
        if (elem == 0 || tree.tags.data[elem] == NodeTag.SPREAD) return false;
    }

    self.has_inferred_name = false;
    self.inferred_name = {};
    self.gen_line_main(init);
    ushort floor = self.next_reg;
    defer self.free_regs_to(floor);
    ushort[64] values;
    for (uint i = 0; i < count; i++) values[i] = self.alloc_persistent_reg();
    ushort eval_floor = self.next_reg;
    // Evaluate the entire literal before binding or inspecting iterator
    // methods: an element expression can replace the array iterator.
    for (uint i = 0; i < count; i++) {
        uint elem = tree.list_item(elems, i);
        Val value = self.gen_expr(elem, 0)!;
        self.gen_line_end(elem);
        self.emit_abc(Opcode.LDREG, values[i], value.reg, 0);
        self.free_regs_to(eval_floor);
    }
    self.gen_line_end(init);
    self.emit_simple(Opcode.ARRAY_PATTERN_GUARD);
    uint slow = self.emit_jump(Opcode.JUMP);
    foreach (i, bind : binds) {
        self.emit_abc(Opcode.LDREG, bind.binding_reg, values[i], 0);
        self.emit_var_store(bind.binding_reg, bind.name_idx, true, kind == CONST);
    }
    uint done = self.emit_jump(Opcode.JUMP);
    self.patch_jump(slow);
    ushort array = self.alloc_reg();
    self.emit_a_bc(Opcode.NEWARR, array, count < hobject::ARRAY_INITIAL_SIZE ? count : 0);
    for (uint i = 0; i < count; i++) self.emit_abc(Opcode.INITELEM, array, i, values[i]);
    self.emit_destructure(binds, false, array, DECLARE, true, kind == CONST)!;
    self.patch_jump(done);
    return true;
}

fn Val? CompilerContext.gen_destruct_assign(&self, uint pattern, uint rhs) {
    DestructBinds binds = { .allocator = mem };
    defer free_destruct_binds(&binds);
    self.gen_collect_pattern(pattern, &binds)!;
    self.resolve_assign_targets(binds.array_view());
    ushort floor = self.next_reg;
    Val value = self.gen_expr(rhs, 0)!;
    self.gen_line_end(rhs);
    self.emit_destructure(binds.array_view(), ast::index_state.tree.tags.data[pattern] == NodeTag.OBJECT_PAT,
        value.reg, ASSIGN_TARGET)!;
    self.free_regs_to(math::max(floor, (ushort)(value.reg + 1)));
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)value.reg, 0);
    return { result, false, 0 };
}


fn void? CompilerContext.gen_for_pattern(&self, uint n, uint pattern, bool declared,
    bool lexical, bool constant, uint saved_scope, ushort saved_reg) {
    ast::Ast* tree = &ast::index_state.tree;
    uint rec = tree.rhs.data[n];
    bool of = tree.tags.data[n] == NodeTag.FOR_OF;
    DestructBinds binds = { .allocator = mem };
    defer free_destruct_binds(&binds);
    self.gen_collect_pattern(pattern, &binds)!;
    if (declared) {
        self.gen_declare_pattern(binds.array_view(), constant ? CONST : lexical ? LET : VAR);
    } else {
        self.resolve_assign_targets(binds.array_view());
    }
    if (lexical) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.gen_tdz_pattern(pattern, saved_scope);
    }
    Val source = self.gen_expr(tree.field(rec, 0), 0)!;
    self.gen_line_end(tree.field(rec, 0));
    if (lexical) {
        self.emit_simple(of ? Opcode.POP_LEX : Opcode.PUSH_LEX);
        self.cur_lex_depth += of ? -1 : 1;
    }
    self.gen_line(tree.field(rec, 2));
    ForOfHead head = { .kind = DESTRUCTURE, .binds = binds.array_view(),
        .store_mode = declared ? DECLARE : ASSIGN_TARGET,
        .is_object_pattern = tree.tags.data[pattern] == NodeTag.OBJECT_PAT,
        .is_lexical = lexical, .is_const = constant };
    uint body = tree.field(rec, 1);
    if (of) {
        self.emit_forof(head, source.reg, saved_scope, saved_reg,
            (tree.flags.data[n] & ast::FOR_AWAIT) != 0, body)!;
        return;
    }
    ushort state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)source.reg, (uint)state, 0);
    uint loop = self.code_count;
    self.push_loop(loop, true);
    ushort key = self.alloc_reg();
    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)key, (uint)has_next, (uint)state);
    uint exit = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);
    self.emit_head_bind(head, key)!;
    self.gen_stmt(body)!;
    self.gen_line_end(body);
    self.innermost_loop().continue_target = self.code_count;
    PerIterBindings cycle;
    cycle.init(mem);
    defer cycle.free();
    foreach (b : binds) {
        if (!b.is_synthetic && lexical && self.is_captured_name(self.bind_name(&b))) cycle.push({ b.name_idx, constant });
    }
    if (cycle.len() != 0) self.emit_create_per_iteration_env(cycle.array_view());
    self.emit(bytecode::make_sabc(Opcode.JUMP, (int)loop - (int)self.code_count - 1));
    self.patch_jump(exit);
    self.pop_loop();
    if (lexical) {
        self.emit_simple(Opcode.POP_LEX);
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth -= 2;
    }
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

fn void? CompilerContext.gen_pattern_parameters(&self, uint params, DestructBind[] binds) {
    ast::Ast* tree = &ast::index_state.tree;
    bool tdz = self.defaults.len() != 0 || self.destruct_defaults.len() != 0;
    foreach (bind : binds) tdz |= bind.has_default || bind.is_computed_key;
    self.ast_param_scope = tdz;
    if (tdz) {
        self.emit_simple(Opcode.PUSH_LEX);
        for (uint i = 0; i < self.scope_depth; i++) {
            ScopeEntry* entry = &self.scope_stack[i];
            if (!entry.is_param) continue;
            entry.is_tdz = true;
            self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(entry.name));
        }
        foreach (&bind : binds) bind.ast_parameter_tdz = true;
    }
    uint cursor = 0;
    for (uint i = 0; i < tree.list_len(params); i++) {
        uint p = tree.list_item(params, i);
        bool rest = tree.tags.data[p] == NodeTag.REST;
        bool has_default = tree.tags.data[p] == NodeTag.ASSIGN_PAT;
        uint target = rest || has_default ? tree.lhs.data[p] : p;
        bool pattern = tree.tags.data[target] != NodeTag.IDENT;
        if (has_default) {
            ushort undef = self.alloc_reg();
            self.emit_abc(Opcode.LDUNDEF, (uint)undef, 0, 0);
            ushort compare = self.alloc_reg();
            self.emit_abc(Opcode.SNEQ, (uint)compare, i, (uint)undef);
            self.free_reg(undef);
            uint skip = self.emit_cond_jump(Opcode.IF_TRUE, (uint)compare);
            self.free_reg(compare);
            if (pattern) {
                foreach (d : self.destruct_defaults) {
                    if (d.arg_slot == i) self.emit_destruct_default(d.default_func_idx, (ushort)i);
                }
            } else {
                foreach (d : self.defaults) {
                    if (d.param_reg != i) continue;
                    if (d.is_literal) {
                        self.emit_a_bc(d.literal.op, i, d.literal.get_bc());
                    } else {
                        self.emit_destruct_default(d.default_func_idx, (ushort)i);
                    }
                }
            }
            self.patch_jump(skip);
        }
        if (pattern) {
            self.emit_abc(Opcode.REQUIRE_OBJ, i, 0, 0);
            uint start = cursor;
            while (cursor < binds.len && binds[cursor].arg_idx == i) cursor++;
            DestructBind[] part = binds[start:cursor - start];
            foreach (&bind : part) {
                if (bind.parent_idx != 0xFFFF) bind.parent_idx -= (ushort)start;
            }
            self.emit_destruct_bindings(part)!;
        } else if (tdz) {
            uint name = self.add_string_constant(self.gen_name(tree.lhs.data[target]));
            self.emit_var_store((ushort)i, name, true, false);
            self.emit_a_bc(Opcode.PUTVAR, i, name);
            self.emit_a_bc(Opcode.GETVAR, i, name);
        }
    }
}

fn void CompilerContext.gen_optional_test(&self, ushort value, List{uint}* jumps) {
    ushort compare = self.alloc_reg();
    self.emit_abc(Opcode.LDNULL, (uint)compare, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)compare, (uint)value, (uint)compare);
    jumps.push(self.emit_cond_jump(Opcode.IF_TRUE, (uint)compare));
    self.emit_abc(Opcode.LDUNDEF, (uint)compare, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)compare, (uint)value, (uint)compare);
    jumps.push(self.emit_cond_jump(Opcode.IF_TRUE, (uint)compare));
    self.free_reg(compare);
}

fn Val? CompilerContext.gen_optional_chain(&self, uint n, bool deleting = false) {
    ast::Ast* tree = &ast::index_state.tree;
    uint inner = tree.lhs.data[n];
    NodeTag tag = tree.tags.data[inner];
    bool member_delete = deleting && (tag == NodeTag.MEMBER || tag == NodeTag.INDEX);
    List{uint} jumps;
    jumps.init(mem);
    defer jumps.free();
    Phase phase = MEMBER;
    MemberTarget target;
    Val value = self.gen_chain(inner, &phase, member_delete ? &target : null, optional: &jumps)!;
    self.gen_line_end(n);
    if (member_delete) {
        Instruction read = self.code[self.code_count - 1];
        self.code[self.code_count - 1] = bytecode::make_abc(Opcode.DELPROP, read.a, read.b, read.c);
        self.free_reg(target.key);
        self.free_val(target.base);
    } else if (deleting) {
        self.free_val(value);
        value.reg = self.alloc_reg();
        self.emit_abc(Opcode.LDTRUE, (uint)value.reg, 0, 0);
    }
    uint skip = self.emit_jump(Opcode.JUMP);
    foreach (jump : jumps) self.patch_jump(jump);
    self.emit_abc(deleting ? Opcode.LDTRUE : Opcode.LDUNDEF, (uint)value.reg, 0, 0);
    self.patch_jump(skip);
    if (deleting || !self.inside_parens) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }
    value.local = false;
    return value;
}

fn Val? CompilerContext.gen_import(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    Val specifier = self.gen_expr(tree.lhs.data[n], 0)!;
    ushort spec = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)spec, (uint)specifier.reg, 0);
    self.free_val(specifier);
    ushort options = self.alloc_reg();
    uint option_node = tree.rhs.data[n];
    if (option_node != 0) {
        Val value = self.gen_expr(option_node, 0)!;
        self.emit_abc(Opcode.LDREG, (uint)options, (uint)value.reg, 0);
        self.free_val(value);
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)options, 0, 0);
    }
    self.gen_line_end(n);
    self.free_reg(options);
    self.free_reg(spec);
    ushort result = self.alloc_reg();
    Opcode op = (tree.flags.data[n] & ast::IMPORT_CALL_DEFER) != 0 ? Opcode.DYN_IMPORT_DEFER
        : (tree.flags.data[n] & ast::IMPORT_CALL_SOURCE) != 0 ? Opcode.DYN_IMPORT_SOURCE : Opcode.DYN_IMPORT;
    self.emit_abc(op, (uint)result, (uint)spec, (uint)options);
    self.call_prop_obj_reg = REG_NONE;
    return { result, false, 0 };
}

fn Val? CompilerContext.gen_tagged_template(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    uint tag = tree.lhs.data[n];
    Phase phase = MEMBER;
    Val callee = is_chain_link(tree.tags.data[tag]) ? self.gen_chain(tag, &phase)! : self.gen_expr(tag, 0)!;
    ushort receiver = self.call_prop_obj_reg;
    self.call_prop_obj_reg = REG_NONE;
    // Substitutions can assign to the identifier holding the tag or its receiver.
    if (callee.local && callee.reg == callee.lreg) {
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)callee.reg, 0);
        callee.reg = saved;
    }
    if (receiver != REG_NONE && self.is_local_var_reg(receiver)) {
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)receiver, 0);
        receiver = saved;
    }
    List{TemplatePart} parts;
    parts.init(mem);
    defer parts.free();
    List{ushort} expressions;
    expressions.init(mem);
    defer expressions.free();
    uint list = tree.lhs.data[tree.rhs.data[n]];
    uint count = tree.template_exprs(list);
    for (uint i = 0; i <= count; i++) {
        uint cooked = tree.template_cooked(list, i);
        parts.push({ cooked == ast::INVALID_ATOM ? 0 : self.add_string_constant(tree.atoms.get(cooked)),
            self.add_string_constant(tree.atoms.get(tree.template_raw(list, i))), cooked == ast::INVALID_ATOM });
        if (i != count) {
            Val value = self.gen_expr(tree.template_expr(list, i), 0)!;
            if (value.local && value.reg == value.lreg) {
                ushort saved = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)saved, (uint)value.reg, 0);
                value.reg = saved;
            }
            expressions.push(value.reg);
        }
    }
    self.gen_line_end(n);
    ushort result = self.emit_template_call(callee.reg, receiver, parts.array_view(), expressions.array_view());
    self.call_prop_obj_reg = REG_NONE;
    return { result, false, 0 };
}

// Class lowering shares the prototype, brand and initializer installation with the token path.
fn Val? CompilerContext.gen_class(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    bool decl = tree.tags.data[n] == NodeTag.CLASS_DECL;
    uint id = tree.lhs.data[n];
    char[] name = id != 0 ? self.gen_name(tree.lhs.data[id]) : decl ? "*default*" : "";
    uint saved_scope = self.scope_depth;
    ushort name_reg = REG_NONE;
    uint name_idx = 0;
    if (decl) {
        self.check_lexical_redeclares_param(name)!;
        name_reg = self.declare_var(name, LET);
        name_idx = self.add_string_constant(name);
        saved_scope = self.scope_depth;
    } else if (id != 0) {
        self.push_scope_marker(false);
        name_reg = self.declare_var(name, LET);
        name_idx = self.add_string_constant(name);
        self.has_inferred_name = false;
        self.inferred_name = {};
    } else if (self.has_inferred_name) {
        name = self.inferred_name;
        self.has_inferred_name = false;
        self.inferred_name = {};
    }
    if (name_reg != REG_NONE) {
        // Heritage runs with the inner class name still uninitialized.
        self.scope_stack[self.scope_depth - 1].is_tdz = true;
    }
    self.gen_line(id != 0 ? tree.end_tok.data[id] : tree.main_tok.data[n]);
    self.emit_simple(Opcode.PUSH_LEX);
    if (name_reg != REG_NONE) self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
    ushort result = self.gen_class_body(name, tree.main_tok.data[n], !decl,
        name_reg, name_idx, is_default_export: decl && id == 0, ast_node: n)!;
    if (name_reg != REG_NONE) self.scope_stack[self.scope_depth - 1].is_tdz = false;
    if (decl) self.emit_a_bc(Opcode.PUTLEX, (uint)name_reg, name_idx);
    self.pop_scope_to(saved_scope);
    self.call_prop_obj_reg = REG_NONE;
    return { result, false, 0 };
}

fn Token CompilerContext.gen_key_token(&self, uint key) {
    ast::Ast* tree = &ast::index_state.tree;
    Token token = lexer::make_token(TokenType.IDENTIFIER, tree.position(tree.main_tok.data[key]).line, 0);
    switch (tree.tags.data[key]) {
        case NUMBER:
            token.type = TokenType.NUMBER;
            ulong bits = ((ulong)tree.rhs.data[key] << 32) | (ulong)tree.lhs.data[key];
            token.num_value = bitcast(bits, double);
        case STRING:
            token.type = TokenType.STRING;
            token.str_value = self.gen_name(tree.lhs.data[key]);
        case BIGINT:
            token.type = TokenType.BIGINT;
            token.str_value = tree.atoms.get(tree.lhs.data[key]);
        case PRIVATE_NAME:
            token.str_value = self.gen_name(tree.lhs.data[key]);
        default:
            break;
    }
    return token;
}

fn void? CompilerContext.gen_private_names(&self, uint members) {
    ast::Ast* tree = &ast::index_state.tree;
    for (uint i = 0; i < tree.list_len(members); i++) {
        uint m = tree.list_item(members, i);
        if (tree.tags.data[m] == NodeTag.STATIC_BLOCK) continue;
        uint key = tree.lhs.data[m];
        if (tree.tags.data[key] != NodeTag.PRIVATE_NAME) continue;
        char[] name = self.gen_name(tree.lhs.data[key]);
        bool is_static = (tree.flags.data[m] & ast::MEMBER_STATIC) != 0;
        if (tree.tags.data[m] == NodeTag.CLASS_METHOD) {
            self.declare_or_merge_private_accessor(name, (tree.flags.data[m] & ast::MEMBER_GET) != 0,
                (tree.flags.data[m] & ast::MEMBER_SET) != 0, is_static)!;
        } else {
            self.declare_private_name(name)!.is_static = is_static;
        }
    }
}

fn Val? CompilerContext.gen_super_call(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    self.gen_line_main(n);
    ushort callee = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)callee, self.super_name_idx);
    self.next_reg = callee + 2;
    Val last;
    ushort spread = REG_NONE;
    ushort count = self.gen_args(tree.rhs.data[n], &callee, &last, &spread)!;
    self.gen_line_end(n);
    self.emit_abc(Opcode.LDUNDEF, (uint)(callee + 1), 0, 0);
    self.emit_abc(spread != REG_NONE ? Opcode.SUPER_CALL_S : Opcode.SUPER_CALL,
        (uint)callee, (uint)callee, spread != REG_NONE ? (uint)spread : (uint)count);
    self.free_regs_to(callee);
    self.next_reg = callee + 1;
    if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
    self.call_prop_obj_reg = REG_NONE;
    return { callee, false, 0 };
}

fn Val? CompilerContext.gen_private_in(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    self.gen_line_main(n);
    char[] slot = self.resolve_private_name(self.gen_name(tree.lhs.data[n]))!.brand_slot_name;
    ushort brand = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)brand, self.add_string_constant(slot));
    Val object = self.gen_expr(tree.rhs.data[n], 0)!;
    self.gen_line_end(n);
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.HAS_BRAND, (uint)result, (uint)object.reg, (uint)brand);
    self.free_val(object);
    self.free_reg(brand);
    return { result, false, 0 };
}

fn bool CompilerContext.gen_call_args_stable(&self, uint first, uint last) {
    ast::Ast* tree = &ast::index_state.tree;
    for (uint i = first; i <= last; i++) {
        if (i - first == 64) return false;
        switch (tree.tags.data[i]) {
            case NUMBER:
            case STRING:
            case BIGINT:
            case REGEX:
            case THIS:
            case NULL_LIT:
            case TRUE_LIT:
            case FALSE_LIT:
            case SEQUENCE:
                break;
            case IDENT:
                if (catch self.resolve_var(self.gen_name(tree.lhs.data[i]))) return false;
            default:
                return false;
        }
    }
    return true;
}

fn void? CompilerContext.gen_block_functions(&self, uint stmts, uint outer_depth) {
    ast::Ast* tree = &ast::index_state.tree;
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint n = self.gen_block_function_node(tree.list_item(stmts, i));
        if (n != 0) self.gen_block_function(n, outer_depth)!;
    }
}

fn void? CompilerContext.gen_block_function(&self, uint n, uint outer_depth) {
    ast::AstIndex* idx = ast::index_state;
    uint atom = idx.tree.lhs.data[idx.tree.lhs.data[n]];
    char[] name = self.gen_name(atom);
    uint fn_scope = idx.function_scope(n);
    uint block = idx.res.scopes.data[fn_scope].parent;
    bool publish = false;
    ast::Scope* sc = &idx.res.scopes.data[block];
    ast::Scope* owner = &idx.res.scopes.data[sc.func];
    for (uint i = owner.site_start; i < owner.site_end; i++) {
        ast::Site* site = &idx.res.sites.data[i];
        if (site.kind == ast::DeclKind.ANNEXB_VAR && site.scope == block
            && idx.tree.lhs.data[site.node] == atom && name != "arguments") {
            publish = true;
            break;
        }
    }
    if (publish) {
        for (uint i = 0; i < outer_depth; i++) {
            if (self.scope_stack[i].name == name) self.mark_scope_captured(i);
        }
    }
    self.has_lexical_bindings = true;
    self.has_local_bindings = true;
    ushort home;
    if (try reg = self.find_same_scope_reg(name)) { home = reg; }
    else { home = self.declare_var(name, VAR, is_fn_decl: true); }
    Val closure = self.gen_closure(n)!;
    self.emit_abc(Opcode.LDREG, (uint)home, (uint)closure.reg, 0);
    uint name_idx = self.add_string_constant(name);
    self.emit_a_bc(Opcode.PUTLEX, (uint)home, name_idx);
    if (publish) self.emit_a_bc(self.is_global ? Opcode.DECLB33GLOBAL : Opcode.DECLGLOBALFUNC, (uint)home, name_idx);
    self.free_val(closure);
}

fn void? CompilerContext.gen_function_stmt(&self, uint n) {
    ast::AstIndex* idx = ast::index_state;
    uint fn_scope = idx.function_scope(n);
    uint parent = idx.res.scopes.data[fn_scope].parent;
    ast::Scope* sc = &idx.res.scopes.data[parent];
    if (sc.kind != ast::ScopeKind.BLOCK && sc.kind != ast::ScopeKind.SWITCH) return;
    if (sc.node == n) {
        uint saved_scope = self.scope_depth;
        ushort saved_reg = self.next_reg;
        self.push_scope_marker();
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.gen_block_function(n, saved_scope)!;
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
        self.pop_scope_to(saved_scope);
        self.free_regs_to(saved_reg);
    } else if (self.cur_with_depth != 0) {
        self.gen_block_function(n, self.scope_depth)!;
    }
}

fn uint CompilerContext.gen_block_function_node(&self, uint n) {
    ast::Ast* tree = &ast::index_state.tree;
    while (tree.tags.data[n] == NodeTag.LABELED) n = tree.rhs.data[n];
    return tree.tags.data[n] == NodeTag.FUNC_DECL ? n : 0;
}

fn bool CompilerContext.gen_target_writes_local(&self, uint n, ushort reg, uint* budget) {
    if (n == 0) return false;
    if (*budget == 0) return true;
    (*budget)--;
    ast::Ast* tree = &ast::index_state.tree;
    switch (tree.tags.data[n]) {
        case IDENT:
            if (try home = self.resolve_var(self.gen_name(tree.lhs.data[n]))) return home == reg;
        case ARRAY_PAT:
        case OBJECT_PAT:
            uint items = tree.lhs.data[n];
            for (uint i = 0; i < tree.list_len(items); i++) {
                if (self.gen_target_writes_local(tree.list_item(items, i), reg, budget)) return true;
            }
        case ASSIGN_PAT:
        case REST:
            return self.gen_target_writes_local(tree.lhs.data[n], reg, budget);
        case PAT_PROP:
            return self.gen_target_writes_local((tree.flags.data[n] & ast::PROP_SHORTHAND_PAT) != 0
                ? tree.lhs.data[n] : tree.rhs.data[n], reg, budget);
        default:
            break;
    }
    return false;
}

fn Val? CompilerContext.gen_invalid_call_target(&self, uint n) {
    Val value = self.gen_expr(n, 0)!;
    self.gen_line_end(n);
    self.emit_a_bc(Opcode.THROW_REF, 0, self.add_string_constant("Invalid left-hand side in assignment"));
    return value;
}

fn void? CompilerContext.gen_program(&self, bool global_checks = true) {
    ast::AstIndex* idx = ast::index_state;
    ast::Ast* tree = &idx.tree;
    ast::Scope* scope = &idx.res.scopes.data[1];
    uint root = scope.node;
    uint stmts = tree.lhs.data[root];
    self.is_strict = (tree.flags.data[root] & ast::PROGRAM_STRICT) != 0;
    self.lexer.set_strict(self.is_strict);
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint stmt = tree.list_item(stmts, i);
        if (tree.tags.data[stmt] != NodeTag.DIRECTIVE) break;
        self.saw_use_strict |= (tree.flags.data[stmt] & ast::DIR_USE_STRICT) != 0;
    }
    self.gen_line_main(root);
    if (global_checks) {
        for (uint i = scope.site_start; !self.in_eval_code && i < scope.site_end; i++) {
            ast::Site* site = &idx.res.sites.data[i];
            if (site.scope != 1 || (site.kind != ast::DeclKind.LET && site.kind != ast::DeclKind.CONST && site.kind != ast::DeclKind.CLASS)) continue;
            self.emit_a_bc(Opcode.CHKGLOBALLEX, 0, self.add_string_constant(self.gen_name(tree.lhs.data[site.node])));
        }
        self.hoist_decls_in(1, true, true)!;
        self.hoist_global_fn_decls_indexed(true)!;
    }
    if (self.is_module) self.gen_module_metadata(stmts)!;
    self.hoist_global_fn_decls_indexed(false)!;
    if (self.is_module) self.gen_module_slots();
    self.hoist_decls_in(1, true, false)!;
    self.index_captures_of(1);
    self.apply_capture_set();
    self.gen_tdz(stmts, 0);
    self.reserved_regs = self.next_reg;
    for (uint i = 0; i < tree.list_len(stmts); i++) self.gen_stmt(tree.list_item(stmts, i))!;
    if (gen_trace) io::eprintfn("AST-GEN program");
}
