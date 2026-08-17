module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Code emission
// ============================================================================

/// Emit a raw instruction, returning its index in the code array.
fn uint CompilerContext.emit(&self, Instruction inst) {
    self.ensure_code_cap();
    if (self.code_count >= self.code_cap) {
        return self.code_count;  // hard cap reached
    }
    uint idx = self.code_count;
    self.code[idx] = inst;
    if (self.line_table != null) self.line_table[idx] = self.lexer.current.line;
    self.code_count++;
    return idx;
}

/// Emit a WIDE prefix word carrying the extension bytes for the next
/// instruction, returning the prefix's index.
fn uint CompilerContext.emit_wide(&self, uint ext_a, uint ext_b, uint ext_c) {
    self.has_wide = true;
    return self.emit(bytecode::make_wide(ext_a, ext_b, ext_c));
}

/// Emit an instruction in A-B-C format.  When any operand exceeds 255, a
/// WIDE prefix word carrying the high-order bytes is emitted first, so the
/// effective operands are 16 bits wide.
fn uint CompilerContext.emit_abc(&self, Opcode op, uint a, uint b, uint c) {
    if (@unlikely((a | b | c) > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, b >> 8, c >> 8);
    }
    return self.emit(bytecode::make_abc(op, a, b, c));
}

/// Emit an instruction in A-BC format.  A is a register operand and is
/// widened with a WIDE prefix when it exceeds 255; the 16-bit BC field
/// (constant index or immediate) is never widened.
fn uint CompilerContext.emit_a_bc(&self, Opcode op, uint a, uint bc) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    return self.emit(bytecode::make_a_bc(op, a, bc));
}

/// Emit an instruction in A-sBx format.  A is a register operand and is
/// widened when it exceeds 255; the signed 16-bit offset is never widened.
fn uint CompilerContext.emit_a_sbx(&self, Opcode op, uint a, int sbx) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    return self.emit(bytecode::make_a_sbx(op, a, sbx));
}

/// True at true global scope with no nested lexical environment, where at
/// runtime lex_env == global_lex_env and var_env == global_env (both permanent
/// GC roots). Only then is a bare identifier guaranteed to resolve in one of
/// the two global objects, making GETGLOBAL/PUTGLOBAL's slot cache sound.
fn bool CompilerContext.at_global_slot_scope(&self) @inline {
    return self.is_global && self.cur_lex_depth == 0;
}

/// Record the constant-pool index of a top-level var/function name as a
/// statically-declared global, so a later strict assignment whose LHS name
/// interns to the same index can elide the resolvability guard. Interned
/// constants dedupe by content, so the index uniquely identifies the name.
fn void CompilerContext.record_declared_global(&self, uint name_idx) {
    if (self.declared_global_name_idxs.contains(name_idx)) return;
    self.declared_global_name_idxs.push(name_idx);
}

/// True when the LHS name (given by its constant-pool index) is a global this
/// unit itself hoisted (var/function), so a strict plain assignment to it is
/// statically resolvable and needs no RESOLVEVAR/THROW_REF guard.
fn bool CompilerContext.is_declared_global(&self, uint name_idx) {
    return self.declared_global_name_idxs.contains(name_idx);
}

/// Emit a bare-identifier read: GETGLOBAL at global slot scope, else GETVAR.
/// Records last_was_getglobal so the assignment write-back picks PUTGLOBAL.
fn uint CompilerContext.emit_ident_read(&self, uint reg, uint name_idx) {
    if (self.at_global_slot_scope()) {
        self.last_was_getglobal = true;
        if (self.is_prim_only_global(name_idx)) {
            self.last_was_getglobal_prim = true;
            return self.emit_a_bc(Opcode.GETGLOBAL_PRIM, reg, name_idx);
        }
        self.last_was_getglobal_prim = false;
        return self.emit_a_bc(Opcode.GETGLOBAL, reg, name_idx);
    }
    self.last_was_getglobal = false;
    self.last_was_getglobal_prim = false;
    return self.emit_a_bc(Opcode.GETVAR, reg, name_idx);
}

/// Emit a JUMP instruction with a placeholder offset; return the index to patch.
fn uint CompilerContext.emit_jump(&self, Opcode op) {
    return self.emit(bytecode::make_sabc(op, 0));
}

/// Emit a conditional branch with placeholder offset.  The A register is
/// widened with a WIDE prefix when it exceeds 255; the placeholder offset is
/// patched in place by patch_jump, which preserves the prefix word.
fn uint CompilerContext.emit_cond_jump(&self, Opcode op, uint a) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    return self.emit(bytecode::make_a_sbx(op, a, 0));
}

/// Emit a conditional branch back to `target` (a loop back-edge). The
/// offset must be computed AFTER any WIDE prefix is emitted, because the
/// branch's own index is what the VM's pc-relative convention measures
/// from: computing it before emission assumes the branch lands exactly at
/// code_count, which a prefix word shifts by one.
fn uint CompilerContext.emit_cond_jump_back(&self, Opcode op, uint a, uint target) {
    if (@unlikely(a > bytecode::MAX_A)) {
        self.emit_wide(a >> 8, 0, 0);
    }
    int back = (int)target - (int)self.code_count - 1;
    return self.emit(bytecode::make_a_sbx(op, a, back));
}

/// Patch a previously emitted JUMP/BREAK/CONTINUE to target the current code position.
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
        self.code[addr] = bytecode::make_a_sbx(op, a, offset);
    }
}

/// Emit a no-operand instruction.
fn uint CompilerContext.emit_simple(&self, Opcode op) {
    return self.emit(bytecode::make_abc(op, 0, 0, 0));
}
