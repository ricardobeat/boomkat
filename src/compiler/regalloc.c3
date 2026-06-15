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
// Register allocation
// ============================================================================

/// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    ushort reg = self.next_reg;
    self.next_reg++;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return reg;
}

/// Allocate multiple consecutive registers, returning the first.
fn ushort CompilerContext.alloc_regs(&self, ushort count) {
    ushort first = self.next_reg;
    self.next_reg += count;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg) {
        self.next_reg--;
    }
}

/// Free registers back to a saved point.
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}
