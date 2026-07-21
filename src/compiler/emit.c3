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
    self.code_count++;
    return idx;
}

/// Emit an instruction in A-B-C format.
fn uint CompilerContext.emit_abc(&self, Opcode op, uint a, uint b, uint c) {
    return self.emit(bytecode::make_abc(op, a, b, c));
}

/// Emit an instruction in A-BC format.
fn uint CompilerContext.emit_a_bc(&self, Opcode op, uint a, uint bc) {
    return self.emit(bytecode::make_a_bc(op, a, bc));
}

/// True at true global scope with no nested lexical environment, where at
/// runtime lex_env == global_lex_env and var_env == global_env (both permanent
/// GC roots). Only then is a bare identifier guaranteed to resolve in one of
/// the two global objects, making GETGLOBAL/PUTGLOBAL's slot cache sound.
fn bool CompilerContext.at_global_slot_scope(&self) @inline {
    return self.is_global && self.cur_lex_depth == 0;
}

/// Emit a bare-identifier read: GETGLOBAL at global slot scope, else GETVAR.
/// Records last_was_getglobal so the assignment write-back picks PUTGLOBAL.
fn uint CompilerContext.emit_ident_read(&self, uint reg, uint name_idx) {
    if (self.at_global_slot_scope()) {
        self.last_was_getglobal = true;
        return self.emit(bytecode::make_a_bc(Opcode.GETGLOBAL, reg, name_idx));
    }
    self.last_was_getglobal = false;
    return self.emit(bytecode::make_a_bc(Opcode.GETVAR, reg, name_idx));
}

/// Emit an instruction in A-sBx format.
fn uint CompilerContext.emit_a_sbx(&self, Opcode op, uint a, int sbx) {
    return self.emit(bytecode::make_a_sbx(op, a, sbx));
}

/// Emit a JUMP instruction with a placeholder offset; return the index to patch.
fn uint CompilerContext.emit_jump(&self, Opcode op) {
    return self.emit(bytecode::make_sabc(op, 0));
}

/// Emit a conditional branch with placeholder offset.
fn uint CompilerContext.emit_cond_jump(&self, Opcode op, uint a) {
    return self.emit(bytecode::make_a_sbx(op, a, 0));
}

/// Patch a previously emitted JUMP/BREAK/CONTINUE to target the current code position.
fn void CompilerContext.patch_jump(&self, uint addr) {
    if (addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)self.code_count - (int)addr - 1;

    if (op == Opcode.JUMP || op == Opcode.BREAK || op == Opcode.CONTINUE) {
        self.code[addr] = bytecode::make_sabc(op, offset);
    } else {
        // Conditional branch: preserve the A field
        uint a = self.code[addr].a;
        self.code[addr] = bytecode::make_a_sbx(op, a, offset);
    }
}

/// Emit a no-operand instruction.
fn uint CompilerContext.emit_simple(&self, Opcode op) {
    return self.emit(bytecode::make_abc(op, 0, 0, 0));
}
