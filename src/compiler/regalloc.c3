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
        // Out of registers: flag the overflow and clamp. finish() reports it
        // as a COMPILE_ERROR; generation continues, and finish() rejects the emitted code. The comparison is
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

// Reclaim every register at or above `base` that is not the slot of a live
// local binding. Called by statement() after each completed statement.
//
// free_reg is LIFO (it only pops the top of the stack), so sub-expression
// shapes that must free a low register while a higher one is still live
// e.g. a member call's 'this' object register, which sits below the call
// window it outlives, strand registers mid-expression. Statement
// boundaries are where nothing but declared locals may remain live, so
// this is the single point where the stack discipline is restored.
// Local slots allocated during the statement itself (declare_var runs
// inside var/let/const statements) are protected by flooring at the
// highest scope-tracked register.
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

// Allocate a register intended to hold state that must survive one or more
// CALLs (e.g. an accumulator built across a loop that calls `.next()`/`.push()`
// each iteration).
//
// In the sliding-window model a register survives a CALL iff its number is
// below the `callee_reg` of every call made while it is live. This allocator
// hands registers out in ascending order, so allocating such state *before*
// any per-iteration call setup places it below those callee frames. This is a
// thin, intent-documenting wrapper over `alloc_reg`; call it (rather than
// `alloc_reg`) for cross-call live state so the requirement is greppable and
// the ordering constraint is explicit at the call site. See plan 042/043.
fn ushort CompilerContext.alloc_persistent_reg(&self) {
    return self.alloc_reg();
}

// Set up the running-argument-count register for a spread call and shift the
// callee frame up to make room below it.
//
// A spread produces an unbounded number of arguments at runtime, written to
// `[first_arg, first_arg + count)`. The count register (SPREAD_ARG/PUTARG's B
// field, also CALL_S's nargs source) must therefore live *below* `first_arg`,
// or a large enough spread overwrites it with an argument value, and the
// post-spread count store then clobbers a real argument slot (see plan on
// spread-into-call arity). The only registers below `first_arg` are the callee
// and `this` slots, which the call still needs. So we relocate the callee,
// `this`, and the `arg_count` plain arguments already emitted up by
// `2 + SPREAD_EVAL_REGS` and hand the freed low slots back as the count
// register plus an evaluation region, placing them below the new `first_arg`
// where they survive the spread and the call.
//
// A plain argument that follows a spread (`f(...a, x)`) is emitted with PUTARG,
// which writes `x` at the runtime slot `first_arg + count`. Its value operand
// must live below `first_arg`, or a large spread overwrites the value register
// before PUTARG reads it; worse, evaluating it into a register the spread has
// already written to clobbers a real argument. So the frame is shifted up by
// `2 + SPREAD_EVAL_REGS`: the lower freed slot becomes the count register,
// and the next `SPREAD_EVAL_REGS` slots form the evaluation region
// (`spread_eval_base .. new_callee`) that a trailing argument's expression is
// compiled into (see emit_call). The region ends at the shifted callee, so
// the shifted callee/this/argument slots above it stay untouched; an
// expression needing more registers than the region is a compile error, not a
// silently corrupted argument list.
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
