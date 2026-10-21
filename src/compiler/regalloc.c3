module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    if (self.reg_cap != 0xFFFF && self.next_reg >= self.reg_cap) {
        // The cap keeps a spread call's trailing-argument evaluation below
        // first_arg; an expression needing more registers than the reserved
        // region cannot be compiled. Overflow is reported by finish().
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if ((uint)self.next_reg + 1 > MAX_REGISTERS) {
        // Out of registers: clamp and flag the overflow. finish() reports it as a
        // COMPILE_ERROR. The comparison is done in uint, since a ushort increment
        // at the ceiling would wrap to 0 and the guard would never fire.
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return (ushort)(MAX_REGISTERS - 1);
    }
    ushort reg = self.next_reg;
    self.next_reg++;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    return reg;
}

// Allocate multiple consecutive registers, returning the first.
fn ushort CompilerContext.alloc_regs(&self, ushort count) {
    if (self.reg_cap != 0xFFFF && self.next_reg >= self.reg_cap) {
        // See alloc_reg: the spread-call evaluation-region cap.
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if ((uint)self.next_reg + (uint)count > MAX_REGISTERS) {
        // See alloc_reg for why the comparison is done in uint.
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return (ushort)(MAX_REGISTERS - 1);
    }
    ushort first = self.next_reg;
    self.next_reg += count;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    return first;
}

// Free a register (only frees if it's the top of the stack).
// Registers below reserved_regs (parameters, hoisted function-scope slots)
// are permanent for the function's lifetime and never released. An
// expression that happens to return a parameter's register must not let a
// later temp allocation land on it and clobber the parameter.
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg && reg >= self.reserved_regs) {
        self.next_reg--;
    }
}

// Free registers back to a saved point (never below reserved_regs).
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (saved < self.reserved_regs) {
        saved = self.reserved_regs;
    }
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}

// Reclaim every register at or above `base` that is not a live local binding.
// Called by statement() after each completed statement.
//
// free_reg is LIFO, so an expression that frees a low register while a higher
// one is live (e.g. a member call's 'this' below its call window) strands
// registers. Statement boundaries restore the stack. Locals declared by the
// statement itself are protected by flooring at the highest scope-tracked register.
fn void CompilerContext.reclaim_stmt_regs(&self, ushort base) {
    uint floor = self.scope_reg_floor();
    self.free_regs_to(floor > base ? (ushort)floor : base);
}

// One past the highest register a binding in scope occupies.
fn uint CompilerContext.scope_reg_floor(&self) @inline {
    return self.scope_depth > 0 ? self.scope_stack[self.scope_depth - 1].reg_floor : 0;
}

// Allocate a register for state that must survive CALLs, such as an accumulator
// built across a loop that calls `.next()`. A register survives a CALL iff its
// number is below the callee_reg of every call made while it is live. Allocate
// this state before any per-iteration call setup, so it sits below those frames.
// Call this rather than alloc_reg for cross-call state, so the requirement stays
// visible at the call site.
fn ushort CompilerContext.alloc_persistent_reg(&self) {
    return self.alloc_reg();
}

// Set up the running-argument-count register for a spread call and shift the
// callee frame up to make room below it.
//
// A spread writes an unbounded number of arguments to `[first_arg, first_arg +
// count)`, so the count register must sit below `first_arg`, or a large spread
// overwrites it. The callee and `this` slots are the only registers below
// `first_arg`, and the call still needs them. So the callee, `this` and the
// `arg_count` plain arguments already emitted move up by `2 + SPREAD_EVAL_REGS`.
// The freed low slots become the count register and an evaluation region
// (`spread_eval_base .. new_callee`) for a trailing argument's expression. An
// expression needing more registers than the region is a compile error.
//
// A plain argument after a spread (`f(...a, x)`) is written by PUTARG at
// `first_arg + count`, so its value must also sit below `first_arg`.
//
// `callee_reg`, `first_arg`, and `arg_count` are updated in place. Returns the
// count register (initialized to `arg_count` by the caller via LDINT).
const uint SPREAD_EVAL_REGS = 12;
fn ushort CompilerContext.begin_spread_args(&self, ushort* callee_reg, ushort* first_arg, ushort arg_count) {
    ushort old_callee = *callee_reg;
    ushort count_reg = old_callee;
    if ((uint)old_callee + 2 + SPREAD_EVAL_REGS + 2 + (uint)arg_count > MAX_REGISTERS) {
        // The shifted spread frame does not fit in the register file; the
        // uint comparison avoids the ushort wrap at the ceiling. Reported by
        // finish().
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return count_reg;
    }
    ushort new_callee = old_callee + 2 + (ushort)SPREAD_EVAL_REGS;
    self.spread_eval_base = old_callee + 2;
    // Shift callee, this, and the plain args already emitted up by
    // 2 + SPREAD_EVAL_REGS, from the top down so overlapping source/dest
    // registers are not clobbered.
    for (int i = (int)arg_count + 1; i >= 0; i--) {
        self.emit_abc(Opcode.LDREG, (uint)(old_callee + 2 + (uint)SPREAD_EVAL_REGS + (uint)i),
                      (uint)(old_callee + (uint)i), 0);
    }
    *callee_reg = new_callee;
    *first_arg = new_callee + 2;
    // Keep the allocator above the shifted frame so later temps don't land in it.
    ushort frame_top = *first_arg + arg_count;
    if (self.next_reg < frame_top) {
        self.next_reg = frame_top;
    }
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    return count_reg;
}
