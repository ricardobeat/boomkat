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
    // Nothing to allocate: scope_stack is shared with depth tracking.
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
///
/// `is_body` marks the marker a FUNCTION BODY opens, as opposed to a nested
/// BlockStatement. The body's top-level lexical names must not collide with
/// the parameter list (§14.1.2), while a nested block's freely shadow it, so
/// the parameter check has to see through this one marker and stop at any
/// other.
fn void CompilerContext.push_scope_marker(&self, bool is_body = false) {
    // The stack grows on the heap, so the only way to fail here is an
    // allocation failure — which ensure_scope_cap records. A dropped entry
    // would make a declaration invisible to shadowing, TDZ and
    // duplicate-declaration checks, so it must never happen silently.
    self.ensure_scope_cap();
    if (self.scope_depth >= self.scope_cap) { self.scope_overflow = true; }
    if (self.scope_depth < self.scope_cap) {
        self.scope_stack[self.scope_depth].name = (char[]){};
        self.scope_stack[self.scope_depth].reg = 0;
        self.scope_stack[self.scope_depth].kind = SCOPEMARK;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_stack[self.scope_depth].is_param = false;
        self.scope_stack[self.scope_depth].is_body_mark = is_body;
        self.scope_depth++;
    }
}

/// ES2024 §13.7.4.1 / §13.7.5.13 early error for `var` declarations: a var
/// binding must not collide with a let/const/class binding in scope. This
/// covers the for-head rule (BoundNames of the ForDeclaration vs the
/// VarDeclaredNames of the body Statement): while the body compiles, the
/// head's lexical names are on scope_stack, so a body `var` (recursing into
/// nested blocks, per VarDeclaredNames) is caught here. Same-block lex-vs-var
/// conflicts are separately caught by the block() pre-scan; this walks the
/// WHOLE stack (past block markers) because the for-head binding lives in an
/// outer scope relative to the body block. No-op for non-VAR kinds.
/// Call only from true var-declaration sites (var statements, for-head var
/// declarations), and not from catch-param or function-declaration paths, whose
/// bindings follow different scoping rules.
fn void? CompilerContext.check_var_lex_conflict(&self, char[] name, ScopeKind kind) {
    if (kind != ScopeKind.VAR) {
        return;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if ((e.kind == ScopeKind.LET || e.kind == ScopeKind.CONST) && str_eq(e.name, name)) {
            return self.fail("lexical declaration cannot share a name with a var declaration")~;
        }
    }
}

/// ES2024 §14.1.2 / §14.15.1 early error: a lexical declaration at the top
/// level of a parameter list's body scope may not redeclare a BoundName of
/// that parameter list. `function f(p) { let p; }` and
/// `try {} catch (e) { let e; }` are both SyntaxErrors, while a body `var` of
/// the same name stays legal (it resolves to the very same binding), which is
/// why the parameter flag, not `kind`, is what this keys off.
///
/// The walk stops at the first real block boundary: a nested block's lexical
/// names shadow the parameters freely (`function f(p) { { let p; } }` is
/// fine). It crosses AT MOST ONE body marker -- the one belonging to the
/// scope this declaration is in, whose parameters sit immediately below it.
/// Crossing a second would reach an enclosing function's parameter list, which
/// this declaration is free to shadow: in
/// `function outer(e) { try {} catch (x) { function e(){} } }` the inner `e`
/// shadows outer's parameter and is perfectly legal.
fn void? CompilerContext.check_lexical_redeclares_param(&self, char[] name) {
    bool crossed_body_mark = false;
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if (e.kind == SCOPEMARK) {
            if (!e.is_body_mark || crossed_body_mark) return;
            crossed_body_mark = true;
            continue;
        }
        if (e.is_param && str_eq(e.name, name)) {
            return self.fail("lexical declaration cannot redeclare a parameter")~;
        }
    }
}

/// Declare a variable in the current scope.
///
/// `is_param` marks a formal or catch parameter. Such a binding is pushed with
/// kind VAR (it shares `var`'s register and env treatment) but a body
/// `let`/`const` may not redeclare it, so the flag is what lets the
/// duplicate-lexical walk tell it apart from a real `var`.
fn ushort CompilerContext.declare_var(&self, char[] name, ScopeKind kind, bool is_param = false) {    ushort reg = self.alloc_reg();
    // Lexical bindings must survive env-elision when a closure can read them
    // through the env chain (see has_lexical_bindings in the elide/needs_env
    // gates).
    if (kind == LET || kind == CONST) {
        self.has_lexical_bindings = true;
    }
    // Push to scope_stack for all lexical declarations (even at global scope)
    // so duplicate let/const can be detected.  Var at global scope is still
    // hoisted to the function-scoped environment and doesn't need scope
    // tracking; a PARAMETER at global scope (a top-level `catch` clause's) does
    // need it, or the body `let` that may not redeclare it has nothing to see.
    bool push_scope = !self.is_global || kind != VAR || is_param;
    // See push_scope_marker: a dropped entry is a silent wrong answer.
    if (push_scope) { self.ensure_scope_cap(); }
    if (push_scope && self.scope_depth >= self.scope_cap) { self.scope_overflow = true; }
    if (push_scope && self.scope_depth < self.scope_cap) {
        // Locals referenced inside nested callable bodies (or reachable by
        // direct eval) must be env-resident: force every access through
        // GETVAR/PUTVAR so closure and eval reads/writes stay coherent
        // (plan 045; the pre_scan_captures pass fills the capture set).
        bool captured = !self.is_global && kind != SCOPEMARK
                     && self.is_captured_name(name);
        // A `let`/`const` enters its temporal dead zone the moment the binding
        // is declared: any read before the declaration's `PUTLEX`/`PUTLEX_C`
        // emits must throw ReferenceError.  Marking the entry here forces
        // `resolve_var` to emit `GETVAR` (which reads the TDZ sentinel that
        // `block()` / `for_of` / `class` install via `INITTZ`).  Cleared by
        // `emit_var_store` after the publishing `PUTLEX` runs.
        bool is_tdz = kind == LET || kind == CONST;
        self.scope_stack[self.scope_depth].name = name;
        self.scope_stack[self.scope_depth].reg = reg;
        self.scope_stack[self.scope_depth].kind = kind;
        self.scope_stack[self.scope_depth].is_captured = captured;
        self.scope_stack[self.scope_depth].is_tdz = is_tdz;
        self.scope_stack[self.scope_depth].is_param = is_param;
        if (captured) { self.has_captured_local = true; }
        self.scope_depth++;
    }
    return reg;
}

/// Resolve a variable name to its register. Searches from innermost scope out.
/// Returns SCOPE_ERROR if not found or if the variable is captured (must go
/// through the environment chain instead of using a register) or is in TDZ
/// (must go through the env so the runtime TDZ sentinel throws ReferenceError).
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
            // Same for a `let`/`const` in its temporal dead zone: register
            // access would bypass the INITTZ sentinel and return `undefined`,
            // violating §13.3.1 / §14.3.1.2 (TDZ must throw ReferenceError
            // until the initialiser's PUTLEX/PUTLEX_C runs).
            if (self.scope_stack[i].is_captured || self.scope_stack[i].is_tdz) {
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
/// scope stack, such as a top-level `function` declaration promoted straight
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

/// True when `name` has a runtime binding in this module scope: any
/// var/let/const/class/function declared here. A TypeScript type-only name
/// (an `interface` or `type` alias, which the parser erases without a
/// binding) is absent, which is what lets `export { G };` after
/// `interface G {}` erase to nothing instead of registering a phantom
/// export the linker would reject.
fn bool CompilerContext.ts_name_is_runtime_binding(&self, char[] name) {
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if (e.kind != ScopeKind.SCOPEMARK && str_eq(e.name, name)) {
            return true;
        }
    }
    // Top-level function declarations are recorded in hoisted_fn_names, not
    // on the scope stack at the time the export clause is parsed.
    for (ushort h = 0; h < self.hoisted_fn_count; h++) {
        if (str_eq(self.hoisted_fn_names[h], name)) return true;
    }
    return false;
}

/// Resolve a variable name to its register REGARDLESS of capture status.
/// Only for declaration-site checks (e.g. `var` redeclaration must reuse the
/// existing binding, never re-declare and clobber the env value). Normal
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

/// Resolve `name` to its register only if it is bound in the scope a function
/// declaration at the current position belongs to.
///
/// A redeclaration of the same name in that scope is the very same binding, so
/// the second declaration must write into the register the first one already
/// uses (see function_declaration); allocating a fresh one leaves code emitted
/// between the two pointing at a stale object. Stopping at a nested block's
/// SCOPEMARK is what keeps that reuse from reaching an enclosing scope's
/// binding, which a block-nested declaration is free to shadow.
///
/// Like check_lexical_redeclares_param, the walk sees through AT MOST ONE body
/// marker: hoist_decls declares the body's function names before block()
/// pushes that marker, so the binding a textual-position declaration must
/// reuse sits just below it.
fn ushort? CompilerContext.find_same_scope_reg(&self, char[] name) {
    bool crossed_body_mark = false;
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if (e.kind == SCOPEMARK) {
            if (!e.is_body_mark || crossed_body_mark) break;
            crossed_body_mark = true;
            continue;
        }
        if (str_eq(e.name, name)) return e.reg;
    }
    return SCOPE_ERROR~;
}

/// True when `name` is already bound as a formal or catch PARAMETER.
///
/// The hoisting pass uses this for the one case where a hoisted `var` must not
/// create a binding: ES2015 §9.2.10 step 27 initializes a var-declared name to
/// undefined only when it is NOT already a parameter name, so
/// `function f(p){ if (false) { var p = 1; } return p; }` must return the
/// ARGUMENT, not undefined. Leaving the parameter's own binding in place (and
/// emitting no LDUNDEF) is what keeps that value alive; declaring afresh would
/// both write undefined and leave reads pointed at a second, empty slot.
///
/// Gated on `is_param` rather than plain name presence: at hoist time the only
/// bindings in scope ARE the parameters (the body has not been parsed), but the
/// narrower test keeps this correct if that ever stops holding.
fn bool CompilerContext.is_param_name(&self, char[] name) {
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if (e.is_param && str_eq(e.name, name)) {
            return true;
        }
    }
    return false;
}

/// Declare a binding for a for-in/for-of head or a destructuring declarator and
/// return the register it lives in.
///
/// A `var` name does NOT introduce a new binding here: it was already hoisted to
/// the enclosing function scope, so this site must write into the register that
/// hoisted binding owns. Calling declare_var unconditionally would allocate a
/// FRESH register, leave the hoisted one holding its LDUNDEF, and (for a
/// for-head) drop the new entry at the loop's pop_scope_to — so a read
/// afterwards returns undefined instead of the value that was bound.
/// The accompanying DECLVAR keeps the env slot correct, which is why the bug
/// is invisible at global scope and for captured locals (both env-resident)
/// and only bites register-resident function locals.
///
/// Mirrors the reuse-or-declare handling at the plain `for (var i = ...)` and
/// identifier `var` statement declaration sites. `let`/`const` DO introduce a
/// fresh binding at each of these sites, so they always declare.
fn ushort CompilerContext.declare_binding_var(&self, char[] name, ScopeKind kind) {
    if (kind != ScopeKind.VAR) {
        return self.declare_var(name, kind);
    }
    // Capture-blind lookup: a captured var is still the same binding.
    ushort? existing = self.find_local_reg(name);
    if (try er = existing) {
        return er;
    }
    return self.declare_var(name, kind);
}

/// Return the constant-pool name index for `reg`'s binding when it is a CONST
/// declaration in scope_stack; return 0xFFFFFFFF otherwise. Used at every
/// register-only write site (postfix INC/DEC, plain/compound/logical
/// assignment) so a const violation is routed through PUTVAR_ASSIGN /
/// INC_VAR or DEC_VAR. The bare register-only opcode
/// silently succeeds on a const, which is the bug plan 062 group H fixes.
///
/// Returns 0xFFFFFFFF (not 0) for "no match" because add_string_constant can
/// legitimately return 0 for the very first string interned into a fresh pool,
/// and the caller compares against the sentinel to decide whether to emit the
/// const-checking opcode.
///
/// Adds the binding's name to the constant pool on hit, which is idempotent since the same
/// string always interns to the same index), so the caller's emitted opcode
/// references a valid pool slot.
fn uint CompilerContext.find_const_name_idx(&self, ushort reg) {
    if (self.scope_depth == 0) return 0xFFFFFFFF;
    for (uint i = 0; i < self.scope_depth; i++) {
        ScopeEntry* e = &self.scope_stack[i];
        if (e.reg == reg && e.kind == ScopeKind.CONST) {
            return self.add_string_constant(e.name);
        }
    }
    return 0xFFFFFFFF;
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
