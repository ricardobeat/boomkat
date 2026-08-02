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
    if (self.reg_cap != 0xFFFF && reg >= self.reg_cap) {
        // The cap keeps a spread call's trailing-argument evaluation below
        // first_arg; an expression needing more registers than the reserved
        // region cannot be compiled. Overflow is reported by finish().
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if (self.next_reg > MAX_REGISTERS) {
        // Out of registers: flag the overflow and clamp. finish() reports it
        // as a COMPILE_ERROR; compilation continues only to keep the parser
        // in sync, since the emitted code is never run.
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
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
    if (self.reg_cap != 0xFFFF && first >= self.reg_cap) {
        // See alloc_reg: the spread-call evaluation-region cap.
        self.reg_overflow = true;
        self.next_reg = (ushort)MAX_REGISTERS;
        self.max_reg  = (ushort)MAX_REGISTERS;
        return (ushort)(MAX_REGISTERS - 1);
    }
    if (self.next_reg > MAX_REGISTERS) {
        self.reg_overflow = true;
        self.next_reg = (ushort)(MAX_REGISTERS - 1);
        self.max_reg  = (ushort)(MAX_REGISTERS - 1);
        return (ushort)(MAX_REGISTERS - 1);
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
/// Registers below reserved_regs (parameters, hoisted function-scope slots)
/// are permanent for the function's lifetime and never released. An
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
/// shapes that must free a low register while a higher one is still live
/// e.g. a member call's 'this' object register, which sits below the call
/// window it outlives, strand registers mid-expression. Statement
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

/// Set up the running-argument-count register for a spread call and shift the
/// callee frame up to make room below it.
///
/// A spread produces an unbounded number of arguments at runtime, written to
/// `[first_arg, first_arg + count)`. The count register (SPREAD_ARG/PUTARG's B
/// field, also CALL_S's nargs source) must therefore live *below* `first_arg`,
/// or a large enough spread overwrites it with an argument value, and the
/// post-spread count store then clobbers a real argument slot (see plan on
/// spread-into-call arity). The only registers below `first_arg` are the callee
/// and `this` slots, which the call still needs. So we relocate the callee,
/// `this`, and the `arg_count` plain arguments already emitted up by
/// `2 + SPREAD_EVAL_REGS` and hand the freed low slots back as the count
/// register plus an evaluation region, placing them below the new `first_arg`
/// where they survive the spread and the call.
///
/// A plain argument that follows a spread (`f(...a, x)`) is emitted with PUTARG,
/// which writes `x` at the runtime slot `first_arg + count`. Its value operand
/// must live below `first_arg`, or a large spread overwrites the value register
/// before PUTARG reads it; worse, evaluating it into a register the spread has
/// already written to clobbers a real argument. So the frame is shifted up by
/// `2 + SPREAD_EVAL_REGS`: the lower freed slot becomes the count register,
/// and the next `SPREAD_EVAL_REGS` slots form the evaluation region
/// (`spread_eval_base .. first_arg`) that a trailing argument's expression is
/// compiled into (see emit_call). `first_arg` caps allocation there, so an
/// expression needing more registers than the region is a compile error, not a
/// silently corrupted argument list.
///
/// `callee_reg`, `first_arg`, and `arg_count` are updated in place. Returns the
/// count register (initialized to `arg_count` by the caller via LDINT).
const uint SPREAD_EVAL_REGS = 6;
fn ushort CompilerContext.begin_spread_args(&self, ushort* callee_reg, ushort* first_arg, ushort arg_count) {
    ushort old_callee = *callee_reg;
    ushort count_reg = old_callee;
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

/// Compile a spread argument's source expression and return its register.
///
/// The first spread runs against an empty window: no argument values exist
/// at or above `first_arg` yet, so the source is evaluated normally. The
/// only register at risk is the source itself, if the expression lands in
/// `[first_arg + arg_count, ...)` where SPREAD_ARG will write; SPREAD_ARG
/// reads its source register into a local before writing, so the overlap is
/// harmless, and the LDREG below just keeps the source above that window.
///
/// A spread after the first is different: at runtime, registers at or above
/// `first_arg` already hold real argument values from the earlier spread(s)
/// and any PUTARG'd trailing args. Evaluating the source with the normal
/// allocator could land in one of those slots and destroy an argument
/// before SPREAD_ARG runs. So the source is compiled into the reserved
/// below-first_arg region, exactly like a trailing arg (reg_cap = first_arg
/// caps the allocation there; an expression too big for the region is a
/// compile error, not a silently corrupted argument list).
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
