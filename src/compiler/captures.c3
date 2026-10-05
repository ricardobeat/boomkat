module boomkat::compiler;

import boomkat::lexer;
import boomkat::ast;
import std::io;
import std::collections::list;

// Captured bindings and dynamic scopes use environment-backed storage.

// Record a name referenced inside a nested callable body.
fn void CompilerContext.add_captured_name(&self, char[] name) {
    if (self.capture_all) return;
    if (name.len == 0) return;
    foreach (captured : self.captured_names) {
        if (str_eq(captured, name)) return;
    }
    char[] owned = mem::new_array(char, name.len);
    mem::copy(owned.ptr, name.ptr, (sz)name.len);
    self.captured_names.push(owned);
}

// Is this local name captured by a nested callable (or is everything)?
fn bool CompilerContext.is_captured_name(&self, char[] name) {
    if (self.capture_all) return true;
    foreach (captured : self.captured_names) {
        if (str_eq(captured, name)) return true;
    }
    return false;
}

// The same for a function scope the caller already holds.
fn bool CompilerContext.index_captures_of(&self, uint scope) {
    ast::AstIndex* idx = ast::index_state;
    if (scope == 0) return false;
    ast::Scope* sc = &idx.res.scopes.data[scope];
    if ((sc.flags & (ast::SCOPE_CAPTURE_ALL | ast::SCOPE_HAS_WITH)) != 0) {
        self.capture_all = true;
    }
    uint arguments_atom = idx.res.atom_arguments;
    for (uint i = idx.res.func_start.data[scope]; i < idx.res.func_start.data[scope + 1]; i++) {
        ast::Binding* b = &idx.res.bindings.data[idx.res.func_items.data[i]];
        if (idx.is_register_capture(b)) self.add_captured_name(idx.tree.atoms.get(b.name));
        if (b.name != arguments_atom) continue;
        // `arguments` as the function's own implicit object, or declared by the body.
        if (b.kind == ast::DeclKind.ARGUMENTS) {
            if (b.local_ref) self.scan_arguments_mentioned = true;
        } else {
            self.scan_arguments_declared = true;
        }
    }
    return true;
}

// Act on the captured-name set a scan produced.
fn void CompilerContext.apply_capture_set(&self) {
    // Reserve before body temporaries: the VM places callees in sliding
    // argument windows, so persistent storage must sit below those windows.
    if (!self.cell_frame_reserved && !self.disable_optimize && !self.is_global
        && !self.is_arrow && !self.is_generator && !self.is_async
        && !self.in_class_body && !self.is_named_func_expr
        && !self.has_rest && self.defaults.len() == 0
        && self.destruct_defaults.len() == 0 && !self.has_destructured_param
        && !self.capture_all && self.captured_names.len() > 0) {
        self.cell_frame_reg = self.alloc_persistent_reg();
        self.cell_frame_reserved = true;
    }

    // Parameters (and destructured-parameter leaves) were declared before
    // this scan ran, so retroactively mark any the capture set names. Their
    // env copies already exist (param DECLVARs), so flipping reads to GETVAR
    // is safe.
    if (!self.is_global) {
        for (uint i = 0; i < self.scope_depth; i++) {
            if (self.scope_stack[i].kind == SCOPEMARK) continue;
            if (!self.scope_stack[i].is_captured
                && self.is_captured_name(self.scope_stack[i].name)) {
                self.mark_scope_captured(i);
            }
        }
    }
}

// Give `arguments` a register of its own when the body only touches it
// directly. The VM then stores the object there at call entry instead of
// declaring a binding in a freshly created variable environment.
//
// Everything that reaches the name through the environment keeps the binding
// form: a nested callable that mentions it (an arrow reads the enclosing
// function's), direct eval, `with`, and any declaration of the name in the
// body, whose redeclaration rules the binding form already implements.
// Generators and async functions keep it too, since their frames are saved and
// restored around suspension.
//
// Runs after capture resolution and before the body's own bindings are
// declared, so the register sits below every hoisted local.
fn void CompilerContext.reserve_arguments_register(&self) {
    if (self.is_global || self.is_arrow || self.is_generator || self.is_async
        || self.eval_mode || self.in_class_body || self.is_named_func_expr
        || self.disable_optimize || self.capture_all || self.has_rest
        || self.defaults.len() > 0 || self.destruct_defaults.len() > 0
        || self.has_destructured_param || self.forbid_arguments
        || self.scan_has_with || self.outer_with || self.has_with_stmt
        || !self.scan_arguments_mentioned || self.scan_arguments_declared
        || self.is_captured_name("arguments")) return;
    for (uint i = 0; i < self.scope_depth; i++) {
        if (self.scope_stack[i].kind != SCOPEMARK && str_eq(self.scope_stack[i].name, "arguments")) return;
    }
    // The register is the function's `arguments` binding for the whole body.
    // Declared as a parameter, which is what FunctionDeclarationInstantiation
    // step 22 does with the name: `var arguments` then reuses it.
    self.arguments_reg = self.declare_var("arguments", VAR, true);
    self.arguments_in_reg = true;
    self.uses_arguments = true;
}
