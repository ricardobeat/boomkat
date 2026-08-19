module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Scope management
// ============================================================================

// Push a new scope level (for blocks, functions, etc.).
fn void CompilerContext.push_scope(&self) {
    // We use scope_depth as a marker; entries below it belong to outer scopes.
    // Nothing to allocate: scope_stack is shared with depth tracking.
}

// Pop the current scope level, freeing any variables declared in it.
fn void CompilerContext.pop_scope(&self) {
    while (self.scope_depth > 0) {
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        self.free_reg(top.reg);
        self.scope_depth--;
        break;
    }
}

// Pop all scope entries added since `saved_depth`.
fn void CompilerContext.pop_scope_to(&self, uint saved_depth) {
    while (self.scope_depth > saved_depth) {
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        if (top.kind != SCOPEMARK) {
            self.free_reg(top.reg);
        }
        self.scope_depth--;
    }
}

// Push a scope marker to delimit block scope boundaries for duplicate
// let/const detection. The marker has no name and no register.
//
// `is_body` marks the marker a function body opens, as opposed to a nested
// BlockStatement. Top-level lexical names in the body must not collide with
// the parameter list (ES2024 §14.1.2), while a nested block may freely shadow it,
// so the parameter check sees through this one marker and stops at any other.
fn void CompilerContext.push_scope_marker(&self, bool is_body = false) {
    // The stack grows on the heap, so ensure_scope_cap records any allocation failure.
    // A dropped entry would make a declaration invisible to shadowing, TDZ and
    // duplicate-declaration checks.
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

// ES2024 §13.7.4.1 / §13.7.5.13 early error for `var` declarations: a var
// binding must not collide with a let/const/class binding in scope. This
// covers the for-head rule (BoundNames of the ForDeclaration vs the
// VarDeclaredNames of the body Statement): while the body compiles, the
// head's lexical names are on scope_stack, so a body `var` (recursing into
// nested blocks) is caught here. Walks the whole stack past block markers
// because the for-head binding lives in an outer scope relative to the body block.
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

// ES2024 §14.1.2 / §14.15.1 early error: a lexical declaration at the top
// level of a parameter list's body scope may not redeclare a BoundName of that
// parameter list (`function f(p) { let p; }` and `try {} catch (e) { let e; }`
// are SyntaxErrors).
//
// The walk stops at the first real block boundary: a nested block's lexical
// names shadow parameters freely (`function f(p) { { let p; } }` is valid).
// It crosses at most one body marker (the one belonging to the scope this declaration
// is in, whose parameters sit immediately below it). Crossing a second would reach
// an enclosing function's parameter list, which this declaration is free to shadow.
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

// Declare a variable in the current scope.
//
// `is_param` marks a formal or catch parameter. Such a binding is pushed with
// kind VAR (sharing var's register/env treatment), but a body let/const may not
// redeclare it, so this flag lets duplicate-lexical checks tell it apart from a real var.
fn ushort CompilerContext.declare_var(&self, char[] name, ScopeKind kind, bool is_param = false) {    ushort reg = self.alloc_reg();
    // Lexical bindings must survive env-elision when a closure can read them
    // through the env chain.
    if (kind == LET || kind == CONST) {
        self.has_lexical_bindings = true;
    }
    // Push to scope_stack for all lexical declarations (even at global scope)
    // so duplicate let/const can be detected. Var at global scope is hoisted to
    // the function-scoped environment and doesn't need scope tracking.
    bool push_scope = !self.is_global || kind != VAR || is_param;
    if (push_scope) { self.ensure_scope_cap(); }
    if (push_scope && self.scope_depth >= self.scope_cap) { self.scope_overflow = true; }
    if (push_scope && self.scope_depth < self.scope_cap) {
        // Locals referenced inside nested callables or reachable by direct eval
        // must be env-resident: force accesses through GETVAR/PUTVAR.
        bool captured = !self.is_global && kind != SCOPEMARK
                     && self.is_captured_name(name);
        // A let/const enters TDZ upon declaration: any read before PUTLEX/PUTLEX_C
        // must throw ReferenceError. Marking is_tdz forces resolve_var to emit GETVAR
        // (which reads the TDZ sentinel installed via INITTZ).
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

// Resolve a variable name to its register. Searches from innermost scope out.
// Returns SCOPE_ERROR if not found, captured (must go through lex_env chain),
// or in TDZ (must go through env so runtime TDZ sentinel throws ReferenceError).
fn ushort? CompilerContext.resolve_var(&self, char[] name) {
    if (self.scope_depth == 0) {
        return SCOPE_ERROR~;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            // Captured variables force environment lookup. Let/const in TDZ
            // must bypass register access to trigger the INITTZ sentinel check.
            if (self.scope_stack[i].is_captured || self.scope_stack[i].is_tdz) {
                return SCOPE_ERROR~;
            }
            return self.scope_stack[i].reg;
        }
    }
    return SCOPE_ERROR~;
}

// Look up whether a name currently in scope was declared `let`/`const` (lexical).
// Used by `export { name }` to decide whether the local export binding is TDZ-eligible.
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

// True when `name` has a runtime binding in this module scope: any
// var/let/const/class/function declared here. A TypeScript type-only name
// (an `interface` or `type` alias) is absent, which lets `export { G };`
// after `interface G {}` erase cleanly without registering a phantom export.
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

// Resolve a variable name to its register REGARDLESS of capture status.
// Used for declaration-site checks (e.g. var redeclaration reuses the existing binding).
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

// Resolve `name` to its register only if it is bound in the scope a function
// declaration at the current position belongs to.
//
// A redeclaration of the same name in that scope is the same binding, so the
// second declaration writes into the register the first one already uses.
// Stopping at a nested block's SCOPEMARK keeps reuse from reaching an enclosing scope.
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

// True when `name` is already bound as a formal or catch parameter.
//
// The hoisting pass uses this for the case where a hoisted var must not
// create a binding: ES2015 §9.2.10 step 27 initializes a var-declared name to
// undefined only when it is not already a parameter name.
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

// Declare a binding for a for-in/for-of head or a destructuring declarator and return its register.
// A var name does not introduce a new binding here: it was already hoisted to
// the enclosing function scope, so this site writes into the register that hoisted binding owns.
fn ushort CompilerContext.declare_binding_var(&self, char[] name, ScopeKind kind) {
    if (kind != ScopeKind.VAR) {
        return self.declare_var(name, kind);
    }
    ushort? existing = self.find_local_reg(name);
    if (try er = existing) {
        return er;
    }
    return self.declare_var(name, kind);
}

// Return the constant-pool name index for `reg`'s binding when it is a CONST declaration in scope_stack.
// Returns 0xFFFFFFFF (not 0) for no match because add_string_constant can return 0 for the first string.
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

// Check if a register is the slot of a declared local variable/let/const/param.
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

// Shield a computed-member key register from GETPROP's in-place ToPropertyKey writeback.
// If the caller passes a live local register, copy it to a fresh temp so GETPROP
// mutates the temp instead of the local.
fn ushort CompilerContext.shield_computed_key(&self, ushort key_reg) {
    if (!self.is_local_var_reg(key_reg)) return key_reg;
    ushort tmp = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)key_reg, 0);
    return tmp;
}

// True when a bare-identifier assignment to `name` is statically resolvable.
// PutValue (ES2022 §13.15.2 step 1) requires a strict assignment to observe whether
// its LHS resolves before the RHS runs. A binding declared in the current function
// always resolves, so RESOLVEVAR and THROW_UNRESOLVED can be omitted.
// TDZ entries are excluded because reaching them early must throw ReferenceError.
fn bool CompilerContext.is_statically_resolvable_local(&self, char[] name) {
    if (self.is_global) return false;
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        ScopeEntry* e = &self.scope_stack[i];
        if (e.kind == SCOPEMARK) continue;
        if (str_eq(e.name, name)) {
            return !e.is_tdz;
        }
    }
    return false;
}
