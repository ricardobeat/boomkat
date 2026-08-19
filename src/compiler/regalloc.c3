module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Register allocation
// ============================================================================

// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    if (self.reg_cap != 0xFFFF && self.next_reg >= self.reg_cap) {
        // The cap keeps a spread call's trailing-argument evaluation below
        // first_arg: an expression needing more registers than the reserved
        // region cannot be compiled. Overflow is reported by finish().
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if ((uint)self.next_reg + 1 > MAX_REGISTERS) {
        // Out of registers: flag the overflow and clamp. finish() reports it
        // as a COMPILE_ERROR; compilation continues only to keep the parser
        // in sync, since the emitted code is never run. The comparison is
        // done in uint: next_reg is ushort, so a ushort increment at the
        // ceiling would wrap to 0 and the guard would never fire.
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
        // The cap keeps a spread call's evaluation region bounded.
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if ((uint)self.next_reg + (uint)count > MAX_REGISTERS) {
        // Computed in uint to avoid ushort wrap at ceiling.
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
// expression returning a parameter register must not let a later temp allocation
// land on it and clobber the parameter.
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg && reg >= self.reserved_regs) {
        self.next_reg--;
    }
}

// Free the register an expression evaluated into, but only when it is a temporary.
// A let/const slot is allocated after the prologue above reserved_regs, so
// free_reg's guard does not protect it. When the expression was a bare reference
// to such a binding, the returned register is the binding's home slot.
// Callers freeing expression results must use this instead of free_reg.
// Evaluated through last_was_local_var/last_local_var_reg in O(1).
fn void CompilerContext.free_expr_reg(&self, ushort reg) {
    if (self.last_was_local_var && self.last_local_var_reg == reg) return;
    self.free_reg(reg);
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

// Reclaim every register at or above `base` that is not the slot of a live local binding.
// free_reg is LIFO, so sub-expression shapes that free a low register while a
// higher one is still live (e.g. member call 'this' below the call window) can strand
// registers mid-expression. Statement boundaries restore the stack discipline.
fn void CompilerContext.reclaim_stmt_regs(&self, ushort base) {
    ushort floor = base;
    for (uint i = 0; i < self.scope_depth; i++) {
        ScopeEntry* e = &self.scope_stack[i];
        if (e.kind != SCOPEMARK && e.reg >= floor) {
            floor = e.reg + 1;
        }
    }
    self.free_regs_to(floor);
}

// Reserve the callee-frame region for an upcoming CALL (func at callee_reg, `this`
// at callee_reg+1, then nargs argument registers at callee_reg+2 .. callee_reg+1+nargs).
// The VM uses a sliding-window register model: on CALL it overlays the callee's
// frame directly onto the caller's register array starting at callee_reg+2.
fn void CompilerContext.reserve_call_frame(&self, ushort callee_reg, ushort nargs) {
    uint frame_top_u = (uint)callee_reg + 2 + (uint)nargs;   // first register past the args
    if (frame_top_u > MAX_REGISTERS) {
        // The callee frame does not fit in the register file. Reported by
        // finish(); computed in uint because ushort addition wraps at the
        // ceiling.
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return;
    }
    ushort frame_top = (ushort)frame_top_u;
    if (self.next_reg < frame_top) {
        self.next_reg = frame_top;
    }
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
}

// Allocate a register intended to hold state that must survive one or more CALLs.
// In the sliding-window model a register survives a CALL iff its number is below
// the callee_reg of every call made while it is live. Allocating before per-iteration
// call setup places it below those callee frames.
fn ushort CompilerContext.alloc_persistent_reg(&self) {
    return self.alloc_reg();
}

// Set up the running-argument-count register for a spread call and shift the
// callee frame up to make room below it.
// A spread produces an unbounded number of arguments at runtime in [first_arg, first_arg + count).
// The count register and evaluation region live below first_arg so they survive the spread.
const uint SPREAD_EVAL_REGS = 6;
fn ushort CompilerContext.begin_spread_args(&self, ushort* callee_reg, ushort* first_arg, ushort arg_count) {
    ushort old_callee = *callee_reg;
    ushort count_reg = old_callee;
    if ((uint)old_callee + 2 + SPREAD_EVAL_REGS + 2 + (uint)arg_count > MAX_REGISTERS) {
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return count_reg;
    }
    ushort new_callee = old_callee + 2 + (ushort)SPREAD_EVAL_REGS;
    self.spread_eval_base = old_callee + 2;
    // Shift callee, this, and the plain args already emitted up by
    // 2 + SPREAD_EVAL_REGS, from the top down so overlapping registers are not clobbered.
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

// Compile a spread argument's source expression and return its register.
// The first spread runs against an empty window. Subsequent spreads compile into
// the reserved below-first_arg region with reg_cap = first_arg to avoid clobbering
// earlier spread results already written at or above first_arg.
fn ushort? CompilerContext.compile_spread_source(&self, ushort first_arg, ushort arg_count, bool is_first_spread) {
    ushort spread_reg;
    if (is_first_spread) {
        spread_reg = self.assignment_expr()!;
        ushort dest_start = first_arg + arg_count;
        if (spread_reg >= dest_start && spread_reg <= dest_start + 10) {
            ushort safe_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)safe_reg, (uint)spread_reg, 0);
            self.free_reg(spread_reg);
            spread_reg = safe_reg;
        }
    } else {
        ushort saved_cap = self.reg_cap;
        self.next_reg = self.spread_eval_base;
        self.reg_cap = first_arg;
        spread_reg = self.assignment_expr()!;
        self.reg_cap = saved_cap;
    }
    return spread_reg;
}
