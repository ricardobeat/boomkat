module tinyduck::compiler;

import tinyduck::types;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::heap;
import libc;
import std::io;

// ============================================================================
// Code emission
// ============================================================================

/// Emit a raw instruction, returning its index in the code array.
fn uint CompilerContext.emit(&self, Instruction inst) {
    if (self.code_count >= MAX_CODE) {
        return self.code_count;  // silently cap (real impl would error)
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

/// Patch a previously emitted JUMP to target the current code position.
fn void CompilerContext.patch_jump(&self, uint addr) {
    if (addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)self.code_count - (int)addr - 1;

    if (op == Opcode.JUMP) {
        self.code[addr] = bytecode::make_sabc(Opcode.JUMP, offset);
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
