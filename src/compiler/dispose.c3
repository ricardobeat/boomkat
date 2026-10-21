// The `using` and `await using` declarations (explicit resource management).
//
// A scope that holds `using` declarations owns a list of resources. The
// compiler collects them there and releases them when the scope is left,
// whatever completion is in flight: a normal exit, a throw, a return, a
// break or a continue.
//
// The release runs in a finally block whose catch records the failure in
// flight, so a disposer that throws while the block is unwinding folds into
// a SuppressedError instead of replacing the original failure. The list and
// the release are the engine's own: the public DisposableStack API is
// mutable, and a user could change what a scope disposes.
//
// A for-of head owns two things, the iteration's resource and the iterator
// itself. ECMA-262 ForIn/OfBodyEvaluation releases the resource first, then
// closes the iterator with the resulting completion.
// Nested regions give that ordering for free: the release is a finally inside
// the loop body, and the close is the finally of a region that encloses the
// whole loop (emit_dispose_close_boundary). Leaving the loop abruptly trips
// both, innermost first, so the close runs last.
module boomkat::compiler;

import boomkat::types;
import boomkat::ast;
import boomkat::bytecode;
import boomkat::hobject;
import boomkat::heap;
import boomkat::builtins;

// Keep a register from being reclaimed at the enclosing statements' boundaries.
fn void CompilerContext.pin_reg(&self, ushort reg) {
    if (self.scope_depth == 0) return;
    ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
    if ((uint)reg + 1 > top.reg_floor) top.reg_floor = (uint)reg + 1;
}

// The register holding a scope's resource list, the register holding the
// failure in flight when the scope is left, and the register telling whether
// there is one. They are allocated below the body's call frames, so the
// body cannot clobber them.
fn DisposeScope CompilerContext.dispose_scope_begin(&self, bool is_async) {
    ushort list_reg = self.alloc_reg();
    ushort pending_reg = self.alloc_reg();
    ushort has_error_reg = self.alloc_reg();
    DisposeScope scope = {
        .list_reg = list_reg,
        .pending_reg = pending_reg,
        .has_error_reg = has_error_reg,
        .is_async = is_async,
    };
    self.emit_abc(Opcode.LDUNDEF, (uint)scope.list_reg, 0, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)scope.pending_reg, 0, 0);
    self.emit_abc(Opcode.LDFALSE, (uint)scope.has_error_reg, 0, 0);
    // The scope's registers outlive the statements in it, so the statement
    // boundary reclaim must not free them.
    self.pin_reg(has_error_reg);
    return scope;
}

// Whether a statement list declares a `using` resource, and whether one of
// them awaits its disposal. Only the list's own declarations matter: a nested
// block owns its own scope.
fn bool CompilerContext.declares_using(&self, uint stmts, bool* is_async) {
    ast::Ast* tree = &ast::index_state.tree;
    bool found = false;
    for (uint i = 0; i < tree.list_len(stmts); i++) {
        uint stmt = tree.list_item(stmts, i);
        if (tree.tags.data[stmt] != NodeTag.VAR_DECL) continue;
        char kind = tree.flags.data[stmt] & ast::VAR_KIND_MASK;
        if (kind != ast::VAR_KIND_USING && kind != ast::VAR_KIND_AWAIT_USING) continue;
        found = true;
        if (kind == ast::VAR_KIND_AWAIT_USING) *is_async = true;
    }
    return found;
}

// The scope a `using` declaration in hand belongs to.
fn DisposeScope* CompilerContext.current_dispose_scope(&self) {
    if (self.dispose_scopes.len() == 0) return null;
    return &self.dispose_scopes[^1];
}

// Register a resource with the scope's list: the value's dispose method is
// looked up and the pair is appended to the list.
fn void CompilerContext.emit_scope_add_resource(&self, ushort list_reg, ushort value_reg, bool is_async) {
    Builtin helper = is_async ? Builtin.SCOPE_ADD_RESOURCE_ASYNC : Builtin.SCOPE_ADD_RESOURCE;
    TVal callee_fn = types::make_lightfunc((void*)(usz)helper.ordinal);
    ushort callee = self.alloc_regs(4);
    self.emit_abc(Opcode.LDCONST, (uint)callee, self.add_constant(callee_fn), 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)(callee + 1), 0, 0);
    self.emit_abc(Opcode.LDREG, (uint)(callee + 2), (uint)list_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)(callee + 3), (uint)value_reg, 0);
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result, (uint)callee, 2);
    // The helper returns the list with the new resource appended.
    self.emit_abc(Opcode.LDREG, (uint)list_reg, (uint)result, 0);
    self.free_reg(result);
    self.free_regs_to(callee);
}

// Release the scope's resources. A failure replaces the completion in
// flight, or becomes the failure of the scope.
fn void CompilerContext.emit_scope_dispose(&self, DisposeScope scope) {
    Builtin helper = scope.is_async ? Builtin.SCOPE_DISPOSE_ASYNC : Builtin.SCOPE_DISPOSE;
    TVal callee_fn = types::make_lightfunc((void*)(usz)helper.ordinal);
    ushort callee = self.alloc_regs(5);
    self.emit_abc(Opcode.LDCONST, (uint)callee, self.add_constant(callee_fn), 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)(callee + 1), 0, 0);
    self.emit_abc(Opcode.LDREG, (uint)(callee + 2), (uint)scope.list_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)(callee + 3), (uint)scope.pending_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)(callee + 4), (uint)scope.has_error_reg, 0);
    ushort result = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result, (uint)callee, 3);
    if (scope.is_async) {
        // The release awaits only when the scope holds an async resource; an
        // `await using` that never ran leaves the scope's exit synchronous.
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort eq_reg = self.alloc_reg();
        self.emit_abc(Opcode.SEQ, (uint)eq_reg, (uint)result, (uint)undef_reg);
        uint skip = self.emit_cond_jump(Opcode.IF_TRUE, (uint)eq_reg);
        ushort awaited = self.emit_await(result);
        self.free_reg(awaited);
        self.free_reg(eq_reg);
        self.free_reg(undef_reg);
        self.patch_jump(skip);
    } else {
        self.free_reg(result);
    }
    self.free_regs_to(callee);
}

// The start of a scope's release region: a try whose catch records the
// failure in flight and whose finally releases the resources.
fn uint CompilerContext.emit_dispose_try(&self) {
    uint try_pc = self.emit_a_bc(Opcode.TRY, 0, 0);
    self.emit_a_bc(Opcode.NOP, 0, 0);
    self.try_depth++;
    return try_pc;
}

// The end of a scope's release region. `close_reg` is a for-of head's flag,
// REG_NONE for a plain scope.
fn void CompilerContext.emit_dispose_end(&self, uint try_pc, DisposeScope scope, ushort close_reg) {
    self.emit_simple(Opcode.ENDTRY);
    uint skip = self.emit_jump(Opcode.JUMP);
    uint catch_pc = self.code_count;
    // The catch records the failure in flight and falls through to the
    // finally, which folds a disposer failure into it and rethrows it.
    self.emit_abc(Opcode.CATCH, (uint)scope.pending_reg, 0, 0);
    self.emit_abc(Opcode.LDTRUE, (uint)scope.has_error_reg, 0, 0);
    uint finally_pc = self.code_count;
    self.patch_jump(skip);
    self.emit_simple(Opcode.FINALLY);
    if (close_reg != REG_NONE) {
        // A for-of head: the release reports failure by throwing, and the
        // iteration's iterator still closes afterwards. Catch the throw here
        // so the close runs, and let has_error say one is in flight.
        uint release_try = self.emit_a_bc(Opcode.TRY, 0, 0);
        self.emit_a_bc(Opcode.NOP, 0, 0);
        self.emit_scope_dispose(scope);
        self.emit_simple(Opcode.ENDTRY);
        uint released = self.emit_jump(Opcode.JUMP);
        uint release_catch = self.code_count;
        self.emit_abc(Opcode.CATCH, (uint)scope.pending_reg, 0, 0);
        self.emit_abc(Opcode.LDTRUE, (uint)scope.has_error_reg, 0, 0);
        self.patch_jump(released);
        self.set_try(release_try, 1, release_catch - release_try, 0);
        // The failure replaces the completion in flight: the close sees a
        // throw and defers to it, then this rethrows it in turn.
        uint no_error = self.emit_cond_jump(Opcode.IF_FALSE, (uint)scope.has_error_reg);
        self.emit_abc(Opcode.THROW, (uint)scope.pending_reg, 0, 0);
        self.patch_jump(no_error);
    } else {
        self.emit_scope_dispose(scope);
    }
    self.emit_simple(Opcode.ENDFINALLY);
    self.set_try(try_pc, 3, catch_pc - try_pc, finally_pc - try_pc);
    self.try_depth--;
}

// The for-of head's iterator close, in the finally of a region that
// encloses the whole loop. Every abrupt exit from an iteration reaches it
// after that iteration's release: break, return, a throw, or a failing
// disposer. Ordinary exhaustion and a same-loop continue clear close_reg and
// close nothing.
fn void CompilerContext.emit_dispose_close_boundary(&self, uint try_pc, DisposeScope scope, ushort close_reg, ushort iter_reg, bool is_await_loop) {
    uint finally_pc = self.code_count;
    self.emit_simple(Opcode.FINALLY);
    // close_reg records an exit already requested; has_error covers a
    // completion that turned into a throw (a failing disposer on the normal
    // or continue path), which ECMA-262 ForIn/OfBodyEvaluation also closes.
    uint requested = self.emit_cond_jump(Opcode.IF_TRUE, (uint)close_reg);
    uint quiet = self.emit_cond_jump(Opcode.IF_FALSE, (uint)scope.has_error_reg);
    self.patch_jump(requested);
    // IteratorClose: a throw completion wins over a failure from
    // `.return()`, so the close suppresses one only when there is a throw.
    uint propagating = self.emit_cond_jump(Opcode.IF_FALSE, (uint)scope.has_error_reg);
    self.emit_iter_close_reg(iter_reg, is_await_loop, true);
    uint closed = self.emit_jump(Opcode.JUMP);
    self.patch_jump(propagating);
    self.emit_iter_close_reg(iter_reg, is_await_loop, false);
    self.patch_jump(closed);
    self.patch_jump(quiet);
    self.emit_simple(Opcode.ENDFINALLY);
    self.set_try(try_pc, 2, finally_pc - try_pc, finally_pc - try_pc);
}
