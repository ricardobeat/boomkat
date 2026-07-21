module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Scope management
// ============================================================================

/// Push a new scope level (for blocks, functions, etc.).
fn void CompilerContext.push_scope(&self) {
    // We use scope_depth as a marker; entries below it belong to outer scopes.
    // Nothing to allocate — scope_stack is shared with depth tracking.
}

/// Pop the current scope level, freeing any variables declared in it.
fn void CompilerContext.pop_scope(&self) {
    // Walk backwards through scope_stack and remove entries at current depth
    while (self.scope_depth > 0) {
        // Peek at the topmost entry
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        // Free the register
        self.free_reg(top.reg);
        self.scope_depth--;
        break;  // We'll be called in a loop by the block parser
    }
}

/// Pop all scope entries added since `saved_depth`.
fn void CompilerContext.pop_scope_to(&self, uint saved_depth) {
    while (self.scope_depth > saved_depth) {
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        // Scope markers have no register to free.
        if (top.kind != SCOPEMARK) {
            self.free_reg(top.reg);
        }
        self.scope_depth--;
    }
}

/// Push a scope marker to delimit block scope boundaries for duplicate
/// let/const detection.  The marker has no name and no register.
fn void CompilerContext.push_scope_marker(&self) {
    if (self.scope_depth < MAX_SCOPE_DEPTH) {
        self.scope_stack[self.scope_depth].name = (char[]){};
        self.scope_stack[self.scope_depth].reg = 0;
        self.scope_stack[self.scope_depth].kind = SCOPEMARK;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_depth++;
    }
}

/// Declare a variable in the current scope.
fn ushort CompilerContext.declare_var(&self, char[] name, ScopeKind kind) {
    ushort reg = self.alloc_reg();
    // Lexical bindings must survive env-elision when a closure can read them
    // through the env chain (see has_lexical_bindings in the elide/needs_env
    // gates).
    if (kind == LET || kind == CONST) {
        self.has_lexical_bindings = true;
    }
    // Push to scope_stack for all lexical declarations (even at global scope)
    // so duplicate let/const can be detected.  Var at global scope is still
    // hoisted to the function-scoped environment and doesn't need scope tracking.
    // Global `var`s are now ALSO pushed to the scope stack (unless poisoned by
    // capture_all) so resolve_var returns their register → register-residency.
    // When capture_all is set (eval/this/globalThis/window/Function/closure
    // reference at global scope), the var is NOT pushed, so resolve_var misses
    // it and reads/writes fall back to env GETVAR/PUTVAR — the safe, observable
    // path. The global env binding is still created by the hoist/DECLVAR pass
    // for the CHKGLOBALVAR conflict prologue and cross-observer visibility.
    bool push_scope = !self.is_global || kind != VAR || !self.capture_all;
    if (push_scope && self.scope_depth < MAX_SCOPE_DEPTH) {
        // Locals referenced inside nested callable bodies (or reachable by
        // direct eval) must be env-resident: force every access through
        // GETVAR/PUTVAR so closure and eval reads/writes stay coherent
        // (plan 045; the pre_scan_captures pass fills the capture set). At
        // global scope, capture_all forces env-residency for the same reason;
        // additionally only plain `var` (kind==VAR) is eligible for register-
        // residency there — global let/const stay env-resident so their
        // runtime TDZ / const-assignment checks (PUTVAR_ASSIGN / PUTLEX) and
        // block-scoped lifetime are preserved.
        // Budget: cap how many top-level `var`s are register-resident so their
        // slots stay within the 8-bit-addressable register range; the rest are
        // env-resident. Counter (not the reusable register number) so freeing
        // over-budget vars' temp registers can't let a later var slip back
        // under budget. Only applies to global `var`s.
        bool over_reg_budget = self.is_global && kind == VAR
                            && self.reg_resident_global_count >= MAX_REG_RESIDENT_GLOBALS;
        bool captured = kind != SCOPEMARK
                     && (self.capture_all || self.is_captured_name(name)
                         || (self.is_global && kind != VAR)
                         || over_reg_budget);
        if (self.is_global && kind == VAR && !captured) {
            self.reg_resident_global_count++;
        }
        // Escaped identifiers (\uXXXX) are decoded by the lexer into a reused
        // scratch buffer, so `name` may be transient — a later escaped
        // identifier overwrites it, aliasing two distinct bindings in the
        // scope stack (resolve_var would then return the wrong register). At
        // global scope these entries persist for the whole compilation, so
        // intern the name into stable HString storage before storing it.
        char[] stable_name = self.is_global ? self.intern_slot_name(name) : name;
        self.scope_stack[self.scope_depth].name = stable_name;
        self.scope_stack[self.scope_depth].reg = reg;
        self.scope_stack[self.scope_depth].kind = kind;
        self.scope_stack[self.scope_depth].is_captured = captured;
        if (captured) { self.has_captured_local = true; }
        self.scope_depth++;
    }
    return reg;
}

/// Force a scope-stack binding to be environment-resident (resolve_var will
/// return SCOPE_ERROR for it, so reads/writes use GETVAR/PUTVAR). Used for
/// global function declarations, which are hoisted as CLOSURE+DECLVAR into the
/// global env and whose closure identity must stay env-canonical rather than
/// living in a body register. Marks the nearest matching entry.
fn void CompilerContext.mark_env_resident(&self, char[] name) {
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            self.scope_stack[i].is_captured = true;
            // Env-resident global (function decl / destructuring target): its
            // env binding is load-bearing, so disable the whole-context env-
            // write elision — otherwise this binding's DECLVAR would be NOP'd
            // and reads (GETVAR) would hit a nonexistent binding. Pure plain-
            // var programs (no function decls / destructuring globals) have no
            // such binding and still elide → keep the register-residency win.
            if (self.is_global) { self.has_captured_local = true; }
            return;
        }
    }
}

/// Resolve a variable name to its register. Searches from innermost scope out.
/// Returns SCOPE_ERROR if not found or if the variable is captured (must go
/// through the environment chain instead of using a register).
fn ushort? CompilerContext.resolve_var(&self, char[] name) {
    // Search from top of scope stack backwards
    if (self.scope_depth == 0) {
        return SCOPE_ERROR~;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            // If captured (e.g. shadowed by a let/const in an inner scope),
            // force environment lookup so the VM walks the lex_env chain.
            if (self.scope_stack[i].is_captured) {
                return SCOPE_ERROR~;
            }
            return self.scope_stack[i].reg;
        }
    }
    return SCOPE_ERROR~;
}

/// Look up whether a name currently in scope was declared `let`/`const`
/// (lexical) as opposed to `var`. Used by `export { name }` (no `from`
/// clause) to decide whether the local export binding is TDZ-eligible.
/// Defaults to false (treated as `var`) if the name isn't found in the
/// scope stack — e.g. a top-level `function` declaration promoted straight
/// to the module env, which is hoisted and never in TDZ.
fn bool CompilerContext.is_name_lexical(&self, char[] name) {
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].kind == LET || self.scope_stack[i].kind == CONST;
        }
    }
    return false;
}

/// Resolve a variable name to its register REGARDLESS of capture status.
/// Only for declaration-site checks (e.g. `var` redeclaration must reuse the
/// existing binding, never re-declare and clobber the env value) — normal
/// reads/writes must use resolve_var so captured locals stay env-resident.
fn ushort? CompilerContext.find_local_reg(&self, char[] name) {
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].reg;
        }
    }
    return SCOPE_ERROR~;
}

/// Check if a variable is const.
fn bool CompilerContext.is_var_const(&self, char[] name) {
    if (self.scope_depth == 0) {
        return false;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].kind == CONST;
        }
    }
    return false;
}

/// Check if a register is the slot of a declared local variable/let/const/param.
/// Returns true if the register holds a live local binding that must NOT be
/// freed by expression_statement (the binding outlives the expression).
fn bool CompilerContext.is_local_var_reg(&self, ushort reg) {
    if (self.scope_depth == 0) {
        return false;
    }
    for (uint i = 0; i < self.scope_depth; i++) {
        if (self.scope_stack[i].reg == reg) {
            return true;
        }
    }
    return false;
}

/// Shield a computed-member key register from GETPROP's in-place
/// ToPropertyKey writeback: if the caller passes a live-local reg,
/// copy it to a fresh temp so GETPROP can safely mutate the temp
/// instead of the local. Any callsite emitting `GETPROP _, obj, key`
/// on a caller-owned key MUST route the key through this helper first.
/// Returns either the original reg (safe) or the temp copy.
fn ushort CompilerContext.shield_computed_key(&self, ushort key_reg) {
    if (!self.is_local_var_reg(key_reg)) return key_reg;
    ushort tmp = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)key_reg, 0);
    return tmp;
}
