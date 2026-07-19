module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
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
        // Out of registers: flag the overflow and clamp. finish() reports it
        // as a COMPILE_ERROR; compilation continues only to keep the parser
        // in sync — the emitted code is never run.
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
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
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
/// Registers below reserved_regs (parameters, hoisted function-scope slots)
/// are permanent for the function's lifetime and are never released — an
/// expression that happens to return a parameter's register must not let a
/// later temp allocation land on it and clobber the parameter.
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg && reg >= self.reserved_regs) {
        self.next_reg--;
    }
}

/// Free registers back to a saved point (never below reserved_regs).
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (saved < self.reserved_regs) {
        saved = self.reserved_regs;
    }
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}

/// Reclaim every register at or above `base` that is not the slot of a live
/// local binding. Called by statement() after each completed statement.
///
/// free_reg is LIFO (it only pops the top of the stack), so sub-expression
/// shapes that must free a low register while a higher one is still live —
/// e.g. a member call's 'this' object register, which sits below the call
/// window it outlives — strand registers mid-expression. Statement
/// boundaries are where nothing but declared locals may remain live, so
/// this is the single point where the stack discipline is restored.
/// Local slots allocated during the statement itself (declare_var runs
/// inside var/let/const statements) are protected by flooring at the
/// highest scope-tracked register.
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

/// Reserve the callee-frame region for an upcoming CALL whose callee value
/// sits at `callee_reg` (func at callee_reg, `this` at callee_reg+1, then
/// `nargs` argument registers at callee_reg+2 .. callee_reg+1+nargs).
///
/// The VM uses a sliding-window register model: on CALL it overlays the
/// callee's frame directly onto the caller's register array starting at
/// callee_reg+2 (see src/vm/vm_calls.c3 and plan 042). After this call
/// returns, the allocator's next_reg is at or above the first register past
/// the argument area, so no register the allocator later hands out can land
/// inside the callee frame the VM will overlay.
///
/// This is the single source of truth for that reservation. Every CALL
/// emission site must funnel through here instead of open-coding a next_reg
/// bump past `callee_reg + 2 + nargs`.
fn void CompilerContext.reserve_call_frame(&self, ushort callee_reg, ushort nargs) {
    ushort frame_top = callee_reg + 2 + nargs;   // first register past the args
    if (self.next_reg < frame_top) {
        self.next_reg = frame_top;
    }
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
}

/// Allocate a register intended to hold state that must survive one or more
/// CALLs (e.g. an accumulator built across a loop that calls `.next()`/`.push()`
/// each iteration).
///
/// In the sliding-window model a register survives a CALL iff its number is
/// below the `callee_reg` of every call made while it is live. This allocator
/// hands registers out in ascending order, so allocating such state *before*
/// any per-iteration call setup places it below those callee frames. This is a
/// thin, intent-documenting wrapper over `alloc_reg`; call it (rather than
/// `alloc_reg`) for cross-call live state so the requirement is greppable and
/// the ordering constraint is explicit at the call site. See plan 042/043.
fn ushort CompilerContext.alloc_persistent_reg(&self) {
    return self.alloc_reg();
}
