module tinyduck::compiler;

import tinyduck::types;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::heap;
import libc;
import std::io;

// ============================================================================
// Destructuring patterns (array and object)
// ============================================================================

/// Parse array destructuring pattern: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
fn void? CompilerContext.array_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ArrayBind[32] binds;
    uint bind_count = 0;

    // Parse pattern elements, declaring each binding as we go
    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        if (self.check(TokenType.COMMA)) {
            self.advance()!;
            if (bind_count < 32) {
                binds[bind_count].is_hole = true;
                bind_count++;
            }
            continue;
        }

        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(rest_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[bind_count].is_rest = true;
                binds[bind_count].is_hole = false;
                bind_count++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
        if (bind_count < 32) {
            ushort reg = self.declare_var(name_tok.str_value, kind);
            binds[bind_count].reg = reg;
            binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
            binds[bind_count].is_rest = false;
            binds[bind_count].is_hole = false;
            bind_count++;
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            if (binds[i].is_hole) continue;
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS (after all bindings declared, so their regs are below RHS regs)
    ushort rhs_reg = self.assignment_expr()!;

    // Emit code for each binding: get property from RHS, store in binding reg
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_hole) continue;

        if (binds[i].is_rest) {
            // For rest at position 0, just assign RHS directly
            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)rhs_reg, 0);
        } else {
            // Regular element: GETPROP rhs[i] → bind_reg
            ushort idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)idx_reg);
            self.free_reg(idx_reg);
        }

        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

/// Parse object destructuring pattern: {a, b: c} = rhs
/// The '{' has already been consumed.
fn void? CompilerContext.object_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ObjBind[32] binds;
    uint bind_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            Token prop_tok = self.expect(TokenType.IDENTIFIER)!;

            if (self.match(TokenType.COLON)) {
                // Keyed: {key: binding_name}
                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(bind_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                    binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                    bind_count++;
                }
            } else {
                // Shorthand: {name}  →  key="name", binding=name
                if (self.is_strict && is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(prop_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                    binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                    bind_count++;
                }
            }

            if (!self.match(TokenType.COMMA)) break;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS
    ushort rhs_reg = self.assignment_expr()!;

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        ushort key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
        self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
        self.free_reg(key_reg);
        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}
