module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::ast;
import std::io;

// ============================================================================
// Code emission
// ============================================================================

// Emit a raw instruction, returning its index in the code array.
fn uint CompilerContext.emit(&self, Instruction inst) {
    self.ensure_code_cap();
    if (self.code_count >= self.code_cap) {
        return self.code_count;  // hard cap reached
    }
    uint idx = self.code_count;
    self.code[idx] = inst;
    if (self.source_positions != null) {
        self.source_positions[idx] = {
            self.lexer.current.line, self.lexer.current.col, self.lexer.current.pos
        };
    }
    self.code_count++;
    return idx;
}

// Emit a WIDE prefix word carrying the extension bytes for the next
// instruction, returning the prefix's index.
fn uint CompilerContext.emit_wide(&self, uint ext_a, uint ext_b, uint ext_c) {
    self.has_wide = true;
    return self.emit(bytecode::make_wide(ext_a, ext_b, ext_c));
}

// Emit an instruction in A-B-C format.  When any operand exceeds 255, a
// WIDE prefix word carrying the high-order bytes is emitted first, so the
// effective operands are 16 bits wide.
fn uint CompilerContext.emit_abc(&self, Opcode op, uint a, uint b, uint c) {
    if (@unlikely((a | b | c) > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, b >> 8, c >> 8);
    }
    return self.emit(bytecode::make_abc(op, a, b, c));
}

// Emit an instruction in A-BC format.  A WIDE prefix carries A's high byte
// when A exceeds 255 and BC's bits 16-31 when BC exceeds 0xFFFF, so a
// constant index is not limited to 16 bits.
fn uint CompilerContext.emit_a_bc(&self, Opcode op, uint a, uint bc) {
    if (@unlikely(a > bytecode::MAX_A || bc > 0xFFFF)) {
        self.emit_wide(a >> 8, (bc >> 16) & 0xFF, bc >> 24);
    }
    return self.emit(bytecode::make_a_bc(op, a, bc));
}

// Emit an instruction in A-sBx format.  A is a register operand and is
// widened when it exceeds 255; the signed 16-bit offset is never widened.
fn uint CompilerContext.emit_a_sbx(&self, Opcode op, uint a, int sbx) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    return self.emit(bytecode::make_a_sbx(op, a, sbx));
}

const uint NO_KEY_CONST = 0xFFFFFFFF;

// The constant-pool index of a string key that the member read just emitted
// (`LDCONST prop; GETPROP _ = obj, prop`) loaded into `prop`, or NO_KEY_CONST.
// The index is limited to what GETPROPC/PUTPROPC can encode.
fn uint CompilerContext.member_key_const(&self, ushort prop) {
    if (self.code_count < 2 || prop > bytecode::MAX_A) return NO_KEY_CONST;
    Instruction get = self.code[self.code_count - 1];
    Instruction load = self.code[self.code_count - 2];
    if (get.op != Opcode.GETPROP || (ushort)get.c != prop) return NO_KEY_CONST;
    if (load.op != Opcode.LDCONST || (ushort)load.a != prop) return NO_KEY_CONST;
    uint idx = bytecode::code_bc(self.code, self.code_count - 2);
    if (idx > 255 || !self.constants[idx].is_string()) return NO_KEY_CONST;
    return idx;
}

// Store `value` to `obj[prop]`. A constant key is reloaded first, so the read
// that came earlier and this store each own a key register the fusion pass
// can fold into GETPROPC and PUTPROPC.
fn void CompilerContext.emit_member_store(&self, Opcode op, ushort obj, ushort prop, ushort value, uint key_const) {
    if (key_const != NO_KEY_CONST) self.emit_a_bc(Opcode.LDCONST, (uint)prop, key_const);
    self.emit_abc(op, (uint)obj, (uint)prop, (uint)value);
}

// True at true global scope with no nested lexical environment, where at
// runtime lex_env == global_lex_env and var_env == global_env (both permanent
// GC roots). Only then is a bare identifier guaranteed to resolve in one of
// the two global objects, making GETGLOBAL/PUTGLOBAL's slot cache sound.
fn bool CompilerContext.at_global_slot_scope(&self) @inline {
    // Inside `with` the name may resolve to the with-object, so identifiers
    // must go through the env walk (GETVAR) even at top-level scope.
    return self.is_global && self.cur_lex_depth == 0 && self.cur_with_depth == 0;
}

// Record the constant-pool index of a top-level var/function name as a
// statically-declared global, so a later strict assignment whose LHS name
// interns to the same index can elide the resolvability guard. Interned
// constants dedupe by content, so the index uniquely identifies the name.
fn void CompilerContext.record_declared_global(&self, uint name_idx) {
    if (!self.declared_global_name_idxs.is_initialized()) self.declared_global_name_idxs.init(mem);
    self.declared_global_name_idxs.add(name_idx);
}

// True when the LHS name (given by its constant-pool index) is a global this
// unit itself hoisted (var/function), so a strict plain assignment to it is
// statically resolvable and needs no RESOLVEVAR/THROW_REF guard.
fn bool CompilerContext.is_declared_global(&self, uint name_idx) {
    return self.declared_global_name_idxs.is_initialized() && self.declared_global_name_idxs.contains(name_idx);
}

// True when a bare identifier inside a function can only name a property of
// the global objects: no scope around the function binds it, and nothing can
// bind it later, so the name needs no walk of the environment chain. A
// `with` object, a sloppy direct eval's `var` and code that runs in a caller's
// environment (eval, which the resolver never saw) all rule it out. The
// activation's environment then does not matter to GETGLOBAL's slot cache,
// which is keyed by the instruction.
fn bool CompilerContext.is_free_global_name(&self, uint name_idx) {
    if (self.is_global || self.is_module || self.func_ast_scope == 0 || self.in_eval_code) return false;
    if (self.has_direct_eval || self.has_with_stmt || self.outer_with || self.capture_all) return false;
    ast::AstIndex* idx = ast::index_state;
    if (idx == null || !idx.use) return false;
    HString* name = (HString*)self.constants[name_idx].get_heapptr();
    uint atom = idx.tree.atoms.find(name.get_data());
    // A name the source never wrote (a synthetic one) has no binding to find.
    if (atom == 0 || atom == idx.res.atom_arguments) return false;
    // A binding of this function still in its temporal dead zone is read by name.
    for (uint i = 0; i < self.scope_depth; i++) {
        if (str_eq(self.scope_stack[i].name, name.get_data())) return false;
    }
    uint s = self.func_ast_scope;
    while (s != 0) {
        ast::Scope* sc = &idx.res.scopes.data[s];
        if (sc.kind == ast::ScopeKind.WITH || (sc.flags & (ast::SCOPE_HAS_EVAL | ast::SCOPE_CAPTURE_ALL)) != 0) return false;
        // Script-level declarations live in the global objects themselves.
        if (sc.kind != ast::ScopeKind.GLOBAL && idx.res.lookup(s, atom) != 0) return false;
        s = sc.parent;
    }
    return true;
}

// Emit a bare-identifier read: GETGLOBAL at global slot scope, else GETVAR.
// Records last_was_getglobal so the assignment write-back picks PUTGLOBAL.
//
// This is the one place a bare identifier is read by name, so it is also where
// a reference to `arguments` is noted: the callers that resolve the name to a
// local register return before reaching here, which is right, because only the
// implicit binding needs the function to build an arguments object.
fn uint? CompilerContext.emit_ident_read(&self, uint reg, uint name_idx) {
    self.note_arguments_reference_by_index(name_idx)!;
    // A REGISTER-RESIDENT module var reads its home register, the binding's
    // only live storage.
    if (self.is_slot_global_name_index(name_idx)) {
        if (try ushort home = self.resolve_slot_global_by_index(name_idx)) {
            self.last_was_getvar = false;
            self.last_was_getglobal = false;
            self.last_was_local_var = true;
            self.last_local_var_reg = home;
            return self.emit_abc(Opcode.LDREG, reg, (uint)home, 0);
        }
    }
    if (self.at_global_slot_scope() || self.is_free_global_name(name_idx)) {
        self.last_was_getglobal = true;
        return self.emit_a_bc(Opcode.GETGLOBAL, reg, name_idx);
    }
    self.last_was_getglobal = false;
    return self.emit_a_bc(Opcode.GETVAR, reg, name_idx);
}

// Emit a by-name variable store. A PUTVAR_ASSIGN upgrades to PUTVAR_SNAP when
// the LHS Reference's environment was captured before the RHS ran (probe_reg
// holds the RESOLVEVAR EnvRecord*): SetMutableBinding then walks from that env
// so an RHS side effect that introduced a more local binding cannot capture
// the store (ES2022 §13.15.2 PutValue step 5). Falls back to the plain A-BC
// form when the probe or the name does not fit PUTVAR_SNAP's ABC fields.
fn void CompilerContext.emit_var_store_op(&self, Opcode op, ushort value_reg, uint name_idx, ushort probe_reg) {
    if (op == Opcode.PUTVAR_ASSIGN && probe_reg != REG_NONE
        && probe_reg <= bytecode::MAX_B && name_idx <= bytecode::MAX_C) {
        self.emit_abc(Opcode.PUTVAR_SNAP, (uint)value_reg, (uint)probe_reg, name_idx);
        return;
    }
    self.emit_a_bc(op, (uint)value_reg, name_idx);
}

// Emit a JUMP instruction with a placeholder offset; return the index to patch.
fn uint CompilerContext.emit_jump(&self, Opcode op) {
    return self.emit(bytecode::make_sabc(op, 0));
}

// Emit a conditional branch with placeholder offset.  The A register is
// widened with a WIDE prefix when it exceeds 255; the placeholder offset is
// patched in place by patch_jump, which preserves the prefix word.
fn uint CompilerContext.emit_cond_jump(&self, Opcode op, uint a) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    return self.emit(bytecode::make_a_sbx(op, a, 0));
}

// Emit a conditional branch back to `target` (a loop back-edge). The
// offset must be computed AFTER any WIDE prefix is emitted, because the
// branch's own index is what the VM's pc-relative convention measures
// from: computing it before emission assumes the branch lands exactly at
// code_count, which a prefix word shifts by one.
//
// A WIDE prefix only carries forward offsets, so a back-edge too far for the
// 16-bit field branches the other way over a JUMP, whose 24-bit field is signed.
fn uint CompilerContext.emit_cond_jump_back(&self, Opcode op, uint a, uint target) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    int back = (int)target - (int)self.code_count - 1;
    if (back >= bytecode::MIN_SBC) return self.emit(bytecode::make_a_sbx(op, a, back));
    Opcode inverse = op == Opcode.IF_TRUE ? Opcode.IF_FALSE : Opcode.IF_TRUE;
    uint addr = self.emit(bytecode::make_a_sbx(inverse, a, 1));
    self.emit(bytecode::make_sabc(Opcode.JUMP, (int)target - (int)self.code_count - 1));
    return addr;
}

// Write the forward conditional branch at `code[addr]`, landing `offset`
// words past the next one. The 16-bit field is patched in place, so a branch
// spanning further records its target for widen_far_offsets to give it a WIDE
// prefix. JUMP needs neither: its 24-bit field covers MAX_CODE_HARD.
fn void CompilerContext.set_branch(&self, uint addr, Opcode op, uint a, int offset) {
    if (offset < bytecode::MIN_SBC) self.record_error("function too large: a branch reaches back too far");
    bool far = offset > bytecode::MAX_SBC;
    self.code[addr] = bytecode::make_a_sbx(op, a, far ? 0 : offset);
    self.note_far_offset(addr, far, (uint)((int)addr + 1 + offset));
}

// Write the TRY at `try_pc` and its finally slot. Offsets count from the TRY;
// a catch offset past 16 bits is widened like a far branch.
fn void CompilerContext.set_try(&self, uint try_pc, uint flags, uint catch_off, uint finally_off) {
    bool far = catch_off > 0xFFFF;
    self.code[try_pc] = bytecode::make_a_bc(Opcode.TRY, flags, far ? 0 : catch_off);
    self.code[try_pc + 1] = bytecode::make_finally_slot(finally_off);
    self.note_far_offset(try_pc, far, try_pc + catch_off);
}

// Converging exits patch one branch more than once, so the latest write wins.
fn void CompilerContext.note_far_offset(&self, uint addr, bool far, uint target) {
    foreach (i, far_offset : self.far_offsets) {
        if (far_offset.addr == addr) {
            self.far_offsets.remove_at(i);
            break;
        }
    }
    if (far) {
        self.far_offsets.push({ addr, target });
        // The optimization passes read offsets from the 16-bit fields.
        self.has_wide = true;
    }
}

// Patch a previously emitted JUMP to land on `target_addr` rather than on the
// current position. Used when two branches must converge on one exit that has
// not been resolved yet: the earlier branch is aimed at the later one, which
// its own eventual patch then carries the rest of the way.
fn void CompilerContext.patch_jump_to(&self, uint addr, uint target_addr) {
    if (addr >= self.code_count || target_addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)target_addr - (int)addr - 1;
    if (op == Opcode.JUMP || op == Opcode.BREAK || op == Opcode.CONTINUE) {
        self.code[addr] = bytecode::make_sabc(op, offset);
    } else {
        uint a = self.code[addr].a;
        self.set_branch(addr, op, a, offset);
    }
}

// Patch a previously emitted JUMP/BREAK/CONTINUE to target the current code position.
fn void CompilerContext.patch_jump(&self, uint addr) {
    if (addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)self.code_count - (int)addr - 1;

    if (op == Opcode.JUMP || op == Opcode.BREAK || op == Opcode.CONTINUE) {
        self.code[addr] = bytecode::make_sabc(op, offset);
    } else {
        // Conditional branch: preserve the A field (its high byte lives in a
        // preceding WIDE prefix, which patch_jump leaves untouched).
        uint a = self.code[addr].a;
        self.set_branch(addr, op, a, offset);
    }
}

// Emit a no-operand instruction.
fn uint CompilerContext.emit_simple(&self, Opcode op) {
    return self.emit(bytecode::make_abc(op, 0, 0, 0));
}
