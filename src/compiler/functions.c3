module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Function compilation
// ============================================================================

/// Maximum number of bindings collected from destructuring function parameters.
const uint MAX_DESTRUCT_BINDS = 64;

/// Iterator state for a source register used in array destructuring.
struct DestructIterState {
    ushort src_reg;       // the source register this iterator is for
    ushort method_reg;    // register holding the iterator object (result of @@iterator call)
    ushort next_reg;      // register holding the .next method
    ushort callee_reg;    // callee register for .next calls
    ushort callee_this_reg; // this register for .next calls
    ushort save_reg;      // holds the iterator while method_reg is latched
                          // undefined across .next()/.done/.value (throws there
                          // must skip IteratorClose per §7.4.6/§7.4.7)
}

/// How emit_destruct_bindings syncs each leaf binding to the environment.
/// PARAM_SYNC: function parameters — already declared in the env at call entry;
///   PUTVAR + GETVAR reload (PUTVAR clears the source register). The adjacent
///   same-reg/same-name pair is elided by the register-locals pass when the
///   function needs no runtime env.
/// DECLARE: statement declarations (var/let/const [pattern] = rhs) — declare
///   the binding via emit_var_store (DECLVAR / PUTLEX / PUTLEX_C).
/// ASSIGN_TARGET: destructuring assignment ([a, b] = rhs) — register-resident
///   locals are written directly by the extraction (no env op); everything
///   else gets a bare PUTVAR (no GETVAR reload — the pair would be
///   misidentified as loop-var sync and elided, dropping genuine env stores).
enum DestructStoreMode {
    PARAM_SYNC,
    DECLARE,
    ASSIGN_TARGET,
}

/// Collected info for a single destructured binding from a function parameter.
struct DestructBind {
    uint name_idx;       // constant index of the binding name (0xFFFFFFFF for synthetic)
    uint key_idx;        // constant index of the property key (for object patterns)
    char[64] name_buf;   // binding name string buffer (for declare_var)
    ushort name_len;     // length of the binding name
    ushort arg_idx;      // which formal parameter index this belongs to
    ushort index;        // for array patterns: the element index
    bool is_object;      // true = object pattern, false = array pattern
    bool has_default;    // has a default value expression
    bool is_synthetic;   // true = intermediate extraction point (not a user variable)
    bool is_hole;        // true = elision placeholder (iterator must advance, no binding produced)
    uint   default_func_idx;  // index into inner_funcs for default thunk (0xFFFFFFFF if none)
    ushort parent_idx;     // index of the binding whose value is the source for this one (0xFFFF = direct from arg)
    // Assignment-pattern member-expression targets: [obj.x] = v, [...obj.rest] = v
    bool   is_member_target;  // target is a member expression, not a simple identifier
    ushort member_obj_reg;    // register holding the evaluated object (for PUTPROP)
    ushort member_prop_reg;   // register holding the evaluated property key (for PUTPROP)
    // Object-pattern computed keys: { [expr]: x }. The key expression is
    // evaluated once at collect time into a persistent register; the emitter
    // reads the value via GETPROP with that register instead of a constant key.
    bool   is_computed_key;   // true = key comes from computed_key_reg, not key_idx
    ushort computed_key_reg;  // register holding the evaluated computed key
    // ASSIGN_TARGET only: the identifier target is env-resident (did not resolve
    // to a reused local register), so the emitter must PUTVAR by name — this
    // runs the VM's const-assignment check. Set by the assignment collectors;
    // decouples the store decision from is_local_var_reg register-number guessing
    // (a fresh temp can collide with reserved low registers like r0).
    bool   assign_needs_putvar;
    // Deferred member-target evaluation: per ES2022 §13.15.5, the target lref
    // (e.g. {}[thrower()]) is evaluated AFTER the inner iterator is opened, so
    // a throw during evaluation runs IteratorClose. collect_assign_target only
    // parses past the target (its code and registers are discarded) and stores
    // a lexer snapshot here; emit_destruct_bindings re-parses the target at the
    // point of use via emit_deferred_target, so its registers are allocated at
    // the emission watermark and cannot collide with live destructuring state.
    // Heap-allocated (a Lexer embeds a 4KB ident_buf); null = not deferred.
    // Owned by the bind from collect until emit_deferred_target frees it.
    DeferredTarget* deferred_target;
    // Deferred computed-key evaluation for OBJECT ASSIGNMENT patterns only
    // (`{[expr]: target} = rhs`): per ES2022 §13.15.5.3 the computed key
    // expression must evaluate AFTER the RHS (source object), not before it.
    // collect_obj_assign_binds only parses past `[expr]` at collect time (code
    // and registers discarded) and stores a lexer snapshot here;
    // emit_destruct_bindings re-parses it at the point of use via
    // emit_deferred_computed_key, landing the value in computed_key_reg.
    // Heap-allocated; null = not deferred (param/declare paths still evaluate
    // the key eagerly at collect time via computed_key_reg directly).
    DeferredTarget* deferred_computed_key;
    // Private field target: the member target is a private field (this.#field).
    // Used by emit_destruct_bindings to defer the CHK_BRAND until after the
    // source property is read (GetV), per ES2022 §13.15.5.6 evaluation order.
    bool is_private_target;
    // Brand register: for private targets, holds the register with the
    // CHK_BRAND operand (the brand symbol). Set by emit_deferred_target when
    // is_private_target is true and deferred_brand_check is active.
    ushort private_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint private_brand_name_c;
    // Object register for the deferred CHK_BRAND.
    ushort private_brand_obj_reg;
}

/// Lexer position captured by collect_assign_target for a deferred member
/// target, restored into the same Lexer object by emit_deferred_target.
/// (Restoring in place keeps token str_value slices into ident_buf valid.)
struct DeferredTarget {
    Lexer lexer;
    Token[4] pushback;
    uint pushback_count;
}

/// Check if a candidate param name already exists in the seen-params table.
/// Used for ES5 §13.1 strict-mode duplicate-parameter rejection (strict-only
/// engine: always rejects).
fn bool check_dup_param(char[] name, char[64][] seen, ushort[] seen_lens, uint count) {
    for (uint i = 0; i < count; i++) {
        if (seen_lens[i] == name.len) {
            bool match = true;
            for (usz j = 0; j < name.len; j++) {
                if (seen[i][j] != name[j]) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
    }
    return false;
}

/// Parse an object destructuring pattern within a function parameter list.
/// The '{' token has already been consumed.
/// Collects all leaf-level binding names into the provided arrays.
fn void? CompilerContext.collect_obj_param_binds(&self,
    DestructBind[] binds, uint* count, ushort src_reg, ushort parent_idx)
{
    if (self.match(TokenType.RBRACE)) return;  // empty pattern {}

    for (;;) {
        if (self.check(TokenType.RBRACE)) break;

        // Track whether the last parsed element was a nested pattern (synthetic)
        // so that a following `= default` applies to the synthetic, not a leaf.
        ushort outer_synth_idx = 0xFFFF;
        bool last_was_synth = false;

        // Rest element: {...rest}
        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(rest_tok.str_value)) {
                return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[*count].key_idx = 0xFFFF;
                binds[*count].is_object = true;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(rest_tok.str_value.len < 63 ? rest_tok.str_value.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = rest_tok.str_value[j]; }
                (*count)++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Computed property key: {[expr]: target}. Per ES2015 §13.3.3, the
        // key is an AssignmentExpression; the runtime evaluates it at
        // extract time. (No destructuring on the key itself.)
        if (self.check(TokenType.LBRACKET)) {
            self.advance()!; // consume '['
            // Evaluate the computed key expression NOW into a persistent
            // register; the emitter reads the property via GETPROP with this
            // register. (Matches the pre-consolidation for-of behavior of
            // evaluating the key once at pattern-collection time.)
            ushort ck_reg = self.assignment_expr()!;
            self.expect(TokenType.RBRACKET)!;
            self.expect(TokenType.COLON)!;

            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                // Computed key with a nested pattern target: { [k]: {x} }.
                bool is_obj = self.check(TokenType.LBRACE);
                if (*count < binds.len) {
                    binds[*count].is_computed_key = true;
                    binds[*count].computed_key_reg = ck_reg;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    binds[*count].is_synthetic = true;
                    (*count)++;
                }
                ushort synth_idx = (ushort)(*count - 1);
                outer_synth_idx = synth_idx;
                last_was_synth = true;
                self.advance()!; // consume '{' or '['
                if (is_obj) {
                    self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
                }
            } else {
                Token bind = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind.str_value)) return COMPILE_ERROR~;
                if (*count < binds.len) {
                    binds[*count].name_idx = self.add_string_constant(bind.str_value);
                    binds[*count].is_computed_key = true;
                    binds[*count].computed_key_reg = ck_reg;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    if (self.match(TokenType.ASSIGN)) {
                        binds[*count].has_default = true;
                        binds[*count].default_func_idx =
                            self.add_inner_func(self.compile_default_expr(bind.str_value)!);
                    }
                    (*count)++;
                }
                last_was_synth = false;
            }
            if (!self.match(TokenType.COMMA)) break;
            continue;
        }

        // Property name — per ES2015 §13.3.3.7, may be an IdentifierName
        // (incl. reserved words), a string literal, or a numeric literal.
        char[] prop_key = self.destructuring_property_key()!;
        uint prop_key_idx = self.add_string_constant(prop_key);

        if (self.match(TokenType.COLON)) {
            // {source: target} — target can be identifier or nested pattern
            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                // Create a synthetic binding for the intermediate extraction
                // e.g. {a: {x,y}} → synthetic for "a" extracts the nested object
                bool is_obj = self.check(TokenType.LBRACE);
                if (*count < binds.len) {
                    binds[*count].key_idx = prop_key_idx;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    binds[*count].is_synthetic = true;
                    (*count)++;
                }
                ushort synth_idx = (ushort)(*count - 1);
                outer_synth_idx = synth_idx;
                last_was_synth = true;
                self.advance()!; // consume '{' or '['
                if (is_obj) {
                    self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
                }
            } else {
                Token bind = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind.str_value)) {
                    return COMPILE_ERROR~;
                }
                if (*count < binds.len) {
                    binds[*count].name_idx = self.add_string_constant(bind.str_value);
                    binds[*count].key_idx = prop_key_idx;
                    binds[*count].is_object = true;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    ushort nl = (ushort)(bind.str_value.len < 63 ? bind.str_value.len : 63);
                    binds[*count].name_len = nl;
                    for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = bind.str_value[j]; }
                    (*count)++;
                }
            }
        } else {
            // Shorthand: {a} — direct child of this destructuring param
            if (*count < binds.len) {
                binds[*count].name_idx = prop_key_idx;
                binds[*count].key_idx = prop_key_idx;
                binds[*count].is_object = true;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(prop_key.len < 63 ? prop_key.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = prop_key[j]; }
                (*count)++;
            }
        }

        // Default: {a = expr} or {a: pattern = expr} — compile as a thunk
        // function like regular defaults. When the previous element was a
        // nested pattern, the default belongs to the synthetic binding.
        if (self.match(TokenType.ASSIGN)) {
            if (*count > 0) {
                ushort target_idx = last_was_synth ? outer_synth_idx : (ushort)(*count - 1);
                binds[target_idx].has_default = true;
                // Pass the binding name through so NamedEvaluation tags an
                // anonymous fn/arrow/class/gen default with the binding name.
                // (ES2015 §13.3.3.7 step 3 / §14.1.20 SetFunctionName.)
                CompiledFunction* default_func = self.compile_default_expr(binds[target_idx].name_buf[:(uint)binds[target_idx].name_len])!;
                uint def_idx = self.add_inner_func(default_func);
                binds[target_idx].default_func_idx = def_idx;
            }
        }

        if (!self.match(TokenType.COMMA)) break;
        if (self.check(TokenType.RBRACE)) break;
    }

    self.expect(TokenType.RBRACE)!;
    return;
}

/// Parse an array destructuring pattern within a function parameter list.
/// The '[' token has already been consumed.
/// Collects all leaf-level binding names into the provided arrays.
fn void? CompilerContext.collect_arr_param_binds(&self,
    DestructBind[] binds, uint* count, ushort src_reg, ushort parent_idx)
{
    ushort elem_idx = 0;

    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        // Track whether the last parsed element was a nested pattern (synthetic)
        // so that a following `= default` applies to the synthetic, not a leaf.
        ushort outer_synth_idx = 0xFFFF;
        bool last_was_synth = false;

        if (self.match(TokenType.COMMA)) {
            // Elision: record a hole so emit_destruct_bindings advances the
            // iterator at this position per IteratorBindingInitialization §13.3.3.
            if (*count < binds.len) {
                binds[*count].key_idx = 0;
                binds[*count].index = elem_idx;
                binds[*count].is_object = false;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                binds[*count].is_synthetic = true;
                binds[*count].is_hole = true;
                (*count)++;
            }
            elem_idx++;
            continue;
        }

        // Rest element: [...rest] or {...rest}
        if (self.match(TokenType.ELLIPSIS)) {
            // Nested rest pattern: create a synthetic for the rest then recurse
            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                bool is_obj = self.check(TokenType.LBRACE);
                if (*count < binds.len) {
                    binds[*count].key_idx = 0xFFFF;
                    binds[*count].index = elem_idx;
                    binds[*count].is_object = false;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    binds[*count].is_synthetic = true;
                    (*count)++;
                }
                ushort synth_idx = (ushort)(*count - 1);
                outer_synth_idx = synth_idx;
                last_was_synth = true;
                self.advance()!;
                if (is_obj) {
                    self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
                }
            } else {
                Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(rest_tok.str_value)) {
                    return COMPILE_ERROR~;
                }
                if (*count < binds.len) {
                    binds[*count].name_idx = self.add_string_constant(rest_tok.str_value);
                    binds[*count].key_idx = 0xFFFF;
                    binds[*count].index = elem_idx;
                    binds[*count].is_object = false;
                    binds[*count].arg_idx = src_reg;
                    binds[*count].parent_idx = parent_idx;
                    ushort nl = (ushort)(rest_tok.str_value.len < 63 ? rest_tok.str_value.len : 63);
                    binds[*count].name_len = nl;
                    for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = rest_tok.str_value[j]; }
                    (*count)++;
                }
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Nested pattern: create a synthetic binding for the intermediate extraction
        if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
            bool is_obj = self.check(TokenType.LBRACE);
            if (*count < binds.len) {
                binds[*count].key_idx = 0;
                binds[*count].index = elem_idx;
                binds[*count].is_object = false;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                binds[*count].is_synthetic = true;
                (*count)++;
            }
            ushort synth_idx = (ushort)(*count - 1);
            outer_synth_idx = synth_idx;
            last_was_synth = true;
            self.advance()!;
            if (is_obj) {
                self.collect_obj_param_binds(binds, count, src_reg, synth_idx)!;
            } else {
                self.collect_arr_param_binds(binds, count, src_reg, synth_idx)!;
            }
        } else {
            Token bind = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(bind.str_value)) {
                return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx = self.add_string_constant(bind.str_value);
                binds[*count].key_idx = 0;  // use index instead
                binds[*count].index = elem_idx;
                binds[*count].is_object = false;
                binds[*count].arg_idx = src_reg;
                binds[*count].parent_idx = parent_idx;
                ushort nl = (ushort)(bind.str_value.len < 63 ? bind.str_value.len : 63);
                binds[*count].name_len = nl;
                for (int j = 0; j < nl; j++) { binds[*count].name_buf[j] = bind.str_value[j]; }
                (*count)++;
            }
        }

        // Default: [a = expr] or [pattern = expr] — compile as a thunk
        // function like regular defaults. When the previous element was a
        // nested pattern, the default belongs to the synthetic binding.
        if (self.match(TokenType.ASSIGN)) {
            if (*count > 0) {
                ushort target_idx = last_was_synth ? outer_synth_idx : (ushort)(*count - 1);
                binds[target_idx].has_default = true;
                // Pass the binding name through so NamedEvaluation tags an
                // anonymous fn/arrow/class/gen default with the binding name.
                // (ES2015 §13.3.3.7 step 3 / §14.1.20 SetFunctionName.)
                CompiledFunction* default_func = self.compile_default_expr(binds[target_idx].name_buf[:(uint)binds[target_idx].name_len])!;
                uint def_idx = self.add_inner_func(default_func);
                binds[target_idx].default_func_idx = def_idx;
            }
        }

        elem_idx++;

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;
    return;
}

// ---------------------------------------------------------------------------
// Iterator protocol helpers for array destructuring
// ---------------------------------------------------------------------------

/// Emit the full iterator protocol setup for a source register.
/// Sets up: src[Symbol.iterator]() → iterator, iterator.next → next method.
/// Populates the DestructIterState with the register numbers.
fn void CompilerContext.emit_destruct_iter_setup(&self, ushort src_reg, DestructIterState* state) {
    // Get Symbol.iterator from the global Symbol object
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);

    // Look up @@iterator method on source
    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)src_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);

    // Call @@iterator() → iterator object
    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)src_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);

    // Get .next method from iterator
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);

    ushort next_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);

    // Set up callee/this pair for .next calls
    // save_reg must live BELOW the callee window so it survives .next() calls.
    ushort save_reg = self.alloc_reg();

    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

    state.src_reg = src_reg;
    state.method_reg = method_reg;
    state.next_reg = next_reg;
    state.callee_reg = callee_reg;
    state.callee_this_reg = callee_this_reg;
    state.save_reg = save_reg;
}

/// Advance the iterator by calling .next(), extract .value into dest_reg.
/// Must be preceded by emit_destruct_iter_setup for the same iterator state.
fn void CompilerContext.emit_destruct_iter_next(&self, DestructIterState* state, ushort dest_reg) {
    // IteratorBindingInitialization §13.3.3: once the iterator has reported
    // done:true, [[done]] is latched — later elements bind undefined without
    // calling .next() again, and the trailing IteratorClose must be skipped.
    // We encode [[done]] by clearing method_reg to undefined (ITER_CLOSE
    // no-ops on non-objects), so first test it before calling .next().
    ushort exh_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)exh_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)exh_reg, (uint)state.method_reg, (uint)exh_reg);
    uint exhausted_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)exh_reg);
    self.free_reg(exh_reg);

    // Reload callee/this each call (generators may overwrite)
    self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);

    // Latch [[done]] across the protocol calls: §7.4.6/§7.4.7 — a throw from
    // .next() or from reading .done/.value sets [[Done]] before rethrowing,
    // so the enclosing catch must NOT call IteratorClose for it. Park the
    // iterator in save_reg and restore it only on a successful not-done step.
    self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

    // Call .next() → result
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

    // IteratorStep (§7.4.7) reads `.done` first and only reads `.value`
    // (IteratorValue, §7.4.8) when not done — an observable ordering when
    // `.done`/`.value` are accessor properties (a `.value` getter must not
    // run when the iterator reports done:true).
    ushort key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)key_reg);
    uint mark_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    // Not done: extract .value.
    self.emit_abc(Opcode.LDCONST, (uint)key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)dest_reg, (uint)result_reg, (uint)key_reg);
    self.free_reg(done_reg);
    self.free_reg(key_reg);
    self.free_reg(result_reg);
    // Successful not-done step: restore the live iterator for IteratorClose.
    self.emit_abc(Opcode.LDREG, (uint)state.method_reg, (uint)state.save_reg, 0);
    uint end_jump = self.emit_jump(Opcode.JUMP);

    // Exhausted: bind undefined (mark target also clears method_reg, which is
    // already undefined on this path — harmless).
    self.patch_jump(exhausted_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)dest_reg, 0, 0);
    // Just-became-done: IteratorStep returns false without reading .value
    // (§7.4.7), so bind undefined here too — dest_reg was never populated on
    // this path since .value is now only read when not done.
    self.patch_jump(mark_jump);
    self.emit_abc(Opcode.LDUNDEF, (uint)dest_reg, 0, 0);
    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);
    self.patch_jump(end_jump);
}

/// Free registers held by an iterator state.
fn void CompilerContext.free_destruct_iter(&self, DestructIterState* state) {
    self.free_reg(state.callee_this_reg);
    self.free_reg(state.callee_reg);
    self.free_reg(state.save_reg);
    self.free_reg(state.next_reg);
    self.free_reg(state.method_reg);
}

/// Find or create iterator state for a source register.
fn ushort find_destruct_iter(ushort src_reg, DestructIterState[] states, uint* count) {
    for (uint i = 0; i < *count; i++) {
        if (states[i].src_reg == src_reg) return (ushort)i;
    }
    return 0xFFFF;
}

/// Shared emission helper for function-parameter destructuring bindings.
/// Emit object-rest collection into dest_reg: `dest = Object.assign({}, src)`
/// then delete every sibling explicit key (own key list minus the rest target),
/// per ES2018 §13.3.3 RestBindingInitialization / DestructuringAssignment.
/// `binds`/`count` describe the full pattern; `rest_di` is the rest bind whose
/// siblings (same parent_idx) name the properties to exclude. `__proto__` is
/// excluded even if not explicitly listed.
fn void CompilerContext.emit_object_rest(&self,
    ushort dest_reg, ushort src_reg,
    DestructBind[] binds, uint count, uint rest_di)
{
    ushort parent = binds[rest_di].parent_idx;

    // dest = Object.assign({}, src). Call convention: callee, this (=target),
    // then args. This engine's Object.assign uses `this` as the target object,
    // so we pass the fresh {} as `this` and `src` as the single source arg.
    // reserve_call_frame reserves callee+1 (this) and callee+2 (arg0) so no
    // live register leaks into an argument slot (a stale iterator result in an
    // unreserved arg slot would otherwise be merged into the rest object).
    ushort empty_obj_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWOBJ, (uint)empty_obj_reg, 0, 0);

    ushort obj_var_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)obj_var_reg, self.add_string_constant("Object"));
    ushort assign_key_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.LDCONST, (uint)assign_key_reg, self.add_string_constant("assign"));
    ushort assign_method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)assign_method_reg, (uint)obj_var_reg, (uint)assign_key_reg);
    self.free_reg(assign_key_reg);
    self.free_reg(obj_var_reg);

    ushort callee_reg = self.alloc_reg();
    self.reserve_call_frame(callee_reg, 1);
    ushort this_reg = callee_reg + 1;
    ushort src_arg_reg = callee_reg + 2;
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)assign_method_reg, 0);
    self.free_reg(assign_method_reg);
    self.emit_abc(Opcode.LDREG, (uint)this_reg, (uint)empty_obj_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)src_arg_reg, (uint)src_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);
    self.emit_abc(Opcode.LDREG, (uint)dest_reg, (uint)callee_reg, 0);
    self.free_reg(callee_reg);
    self.free_reg(empty_obj_reg);

    // Delete each sibling explicit key from dest.
    uint proto_idx = self.add_string_constant("__proto__");
    for (uint j = 0; j < count; j++) {
        if (j == rest_di) continue;
        if (binds[j].parent_idx != parent) continue;
        if (binds[j].is_object == false) continue;   // array siblings can't share an object parent
        if (binds[j].key_idx == 0xFFFF) continue;     // another rest (shouldn't happen)
        if (binds[j].is_computed_key) {
            // Delete by the runtime computed key value.
            ushort dr = self.alloc_reg();
            self.emit_abc(Opcode.DELPROP, (uint)dr, (uint)dest_reg, (uint)binds[j].computed_key_reg);
            self.free_reg(dr);
            continue;
        }
        if (binds[j].key_idx == proto_idx) continue;  // __proto__ already excluded
        ushort del_key_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)del_key_reg, binds[j].key_idx);
        ushort del_result_reg = self.alloc_reg();
        self.emit_abc(Opcode.DELPROP, (uint)del_result_reg, (uint)dest_reg, (uint)del_key_reg);
        self.free_reg(del_key_reg);
        self.free_reg(del_result_reg);
    }
}

/// Force GetIterator(src) + immediate IteratorClose. Used for an empty array
/// assignment pattern `[] = rhs`: per DestructuringAssignmentEvaluation the
/// pattern still performs GetIterator, so `[] = undefined` must throw TypeError.
fn void CompilerContext.emit_empty_array_iter(&self, ushort src_reg) {
    DestructIterState state;
    self.emit_destruct_iter_setup(src_reg, &state);
    self.emit_abc(Opcode.ITER_CLOSE, (uint)state.method_reg, 0, 0);
    self.free_destruct_iter(&state);
}

/// Walks binds in declaration order, resolving source registers from arg slots
/// or parent group temps, and emits GETPROP (object patterns) or iterator
/// protocol (array patterns) to extract values into group_regs / binding_regs.
fn void CompilerContext.emit_destruct_bindings(&self,
    DestructBind[] binds, uint count,
    ushort[] group_regs, ushort[] binding_regs,
    DestructStoreMode store_mode = PARAM_SYNC,
    bool is_lexical = false, bool is_const = false)
{
    if (count == 0) return;

    DestructIterState[MAX_DESTRUCT_BINDS] iter_states;
    uint iter_count = 0;

    // Track the next expected index per source register (for hole/elision gaps).
    // Source registers are argument slots (low numbers), so we index by arg_idx.
    ushort[64] expected_idx;
    for (uint i = 0; i < 64; i++) expected_idx[i] = 0xFFFF;

    // Pre-scan: allocate group_regs for rest synthetics before any iterator
    // setup, so they land below callee_reg and survive the per-iteration CALL
    // frame overlay (see plan 042/043). alloc_persistent_reg documents that
    // these registers must outlive the collection-loop calls.
    // Also detect whether any array (iterator-based) binds are present so we
    // can decide whether to emit a TRY guard for IteratorClose on abrupt completion.
    bool has_array_binds = false;
    for (uint di = 0; di < count; di++) {
        if (binds[di].is_synthetic && !binds[di].is_object && binds[di].key_idx == 0xFFFF) {
            group_regs[di] = self.alloc_persistent_reg();
        }
        if (binds[di].deferred_target != null) {
            // Stable pair for a deferred member target's evaluated object/key:
            // allocated below every iterator/push callee window so the values
            // survive the protocol CALLs up to the final PUTPROP.
            binds[di].member_obj_reg  = self.alloc_persistent_reg();
            binds[di].member_prop_reg = self.alloc_persistent_reg();
        }
        if (binds[di].deferred_computed_key != null) {
            // Stable register for a deferred computed key's evaluated value:
            // allocated below every callee window so it survives the GETPROP
            // reads and any nested-pattern CALLs up to point of use.
            binds[di].computed_key_reg = self.alloc_persistent_reg();
        }
        if (!binds[di].is_object) has_array_binds = true;
    }

    // IteratorClose on abrupt completion (ES2022 §13.3.3.8):
    // Wrap array-destructuring body in TRY so that any throw during lref
    // evaluation, default-value evaluation, or IteratorStep propagates
    // through a catch block that calls iterator.return() before re-throwing.
    // try_addr / jump_slot_addr track the placeholder instructions; both are
    // set to 0xFFFFFFFF if there are no array binds (no guard needed).
    uint iter_try_addr      = 0xFFFFFFFF;
    uint iter_jump_slot     = 0xFFFFFFFF;
    if (has_array_binds) {
        iter_try_addr   = self.emit_a_bc(Opcode.TRY, 0, 0);
        iter_jump_slot  = self.emit_a_bc(Opcode.NOP, 0, 0);
    }

    for (uint di = 0; di < count; di++) {
        // Resolve source register — either the argument slot or a parent group temp
        ushort src_reg;
        if (binds[di].parent_idx == 0xFFFF) {
            src_reg = binds[di].arg_idx;
        } else {
            src_reg = group_regs[binds[di].parent_idx];
        }

        // ---- Hole / elision: advance iterator past gaps ----
        // For any array bind (not object), ensure iterator is at the target index.
        // This covers: element binds, synthetic binds, and rest binds.
        if (!binds[di].is_object) {
            ushort ei = expected_idx[src_reg];
            if (ei == 0xFFFF) ei = 0;
            ushort target = binds[di].index;
            while (ei < target) {
                ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
                if (iter_idx == 0xFFFF) {
                    iter_idx = (ushort)iter_count;
                    iter_count++;
                    self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
                }
                ushort hole_reg = self.alloc_reg();
                self.emit_destruct_iter_next(&iter_states[iter_idx], hole_reg);
                self.free_reg(hole_reg);
                ei++;
            }
        }
        // Update expected next index after consuming this element.
        if (!binds[di].is_object && binds[di].key_idx != 0xFFFF) {
            if (expected_idx[src_reg] == 0xFFFF) expected_idx[src_reg] = 0;
            expected_idx[src_reg] = (ushort)(binds[di].index + 1);
        }

        // Hole / elision entry: advance iterator once and continue.
        // Per IteratorBindingInitialization §13.3.3, each elision must call
        // IteratorStep and propagate abrupt completions.
        if (binds[di].is_hole) {
            ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
            if (iter_idx == 0xFFFF) {
                iter_idx = (ushort)iter_count;
                iter_count++;
                self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
            }
            ushort hole_reg = self.alloc_reg();
            self.emit_destruct_iter_next(&iter_states[iter_idx], hole_reg);
            self.free_reg(hole_reg);
            if (expected_idx[src_reg] == 0xFFFF) expected_idx[src_reg] = 0;
            expected_idx[src_reg] = (ushort)(binds[di].index + 1);
            continue;
        }

        if (binds[di].is_synthetic) {
            // Use pre-allocated group_reg for rest synthetics, allocate now for others.
            ushort group_reg;
            if (binds[di].key_idx == 0xFFFF) {
                group_reg = group_regs[di];
            } else {
                group_reg = self.alloc_reg();
                group_regs[di] = group_reg;
            }

            if (binds[di].is_object) {
                // Object pattern: GETPROP via a constant or computed key.
                if (binds[di].is_computed_key) {
                    if (binds[di].deferred_computed_key != null) {
                        self.emit_deferred_computed_key(&binds[di]);
                    }
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)binds[di].computed_key_reg);
                } else {
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, binds[di].key_idx);
                    self.emit_abc(Opcode.GETPROP, (uint)group_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                }
            } else if (binds[di].key_idx == 0xFFFF) {
                // Synthetic rest: collect remaining iterator values into an array.
                self.emit_abc(Opcode.NEWARR, (uint)group_reg, 0, 0);

                ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
                if (iter_idx == 0xFFFF) {
                    iter_idx = (ushort)iter_count;
                    iter_count++;
                    self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
                }
                DestructIterState* state = &iter_states[iter_idx];

                ushort result_reg = self.alloc_reg();
                ushort done_key_reg = self.alloc_reg();
                ushort done_reg = self.alloc_reg();

                uint collect_start = self.code_count;

                self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
                self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);

                // Latch [[done]] across the .next() + .done/.value reads: a throw
                // from any of them sets [[Done]] before rethrowing, so the
                // enclosing finally must NOT call IteratorClose for it
                // (§7.4.6/§7.4.8). Park the iterator in save_reg and clear
                // method_reg; restore only after a successful not-done step.
                self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
                self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

                self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

                self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
                uint done_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

                ushort val_key_reg = self.alloc_reg();
                ushort val_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)val_key_reg, self.add_string_constant("value"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)val_key_reg);
                self.free_reg(val_key_reg);
                // Successful not-done step: restore the live iterator so an abrupt
                // completion of the loop body (or a subsequent step) still closes it.
                self.emit_abc(Opcode.LDREG, (uint)state.method_reg, (uint)state.save_reg, 0);

                ushort push_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)push_key_reg, self.add_string_constant("push"), 0);
                ushort push_method_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)push_method_reg, (uint)group_reg, (uint)push_key_reg);
                self.free_reg(push_key_reg);

                ushort push_callee_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)push_callee_reg, (uint)push_method_reg, 0);
                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 1), (uint)group_reg, 0);
                if (self.next_reg < push_callee_reg + 3) {
                    self.next_reg = push_callee_reg + 3;
                }
                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 2), (uint)val_reg, 0);
                self.free_reg(val_reg);
                self.free_reg(push_method_reg);
                self.emit_abc(Opcode.CALL, (uint)push_callee_reg, (uint)push_callee_reg, 1);
                self.free_reg(push_callee_reg);

                int back_offset = (int)collect_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));
                self.patch_jump(done_jump);
                // Rest consumed the iterator to done:true — latch [[done]] so
                // the trailing IteratorClose is skipped (§13.3.3.8 step 4.b).
                self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

                self.free_reg(done_key_reg);
                self.free_reg(done_reg);
                self.free_reg(result_reg);
            } else {
                // Array pattern element: single iterator advance.
                ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
                if (iter_idx == 0xFFFF) {
                    iter_idx = (ushort)iter_count;
                    iter_count++;
                    self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
                }
                self.emit_destruct_iter_next(&iter_states[iter_idx], group_reg);
            }

            // Default value check for nested patterns: if group_reg is
            // undefined, evaluate the default thunk before REQUIRE_OBJ.
            if (binds[di].has_default && binds[di].key_idx != 0xFFFF) {
                ushort undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                ushort cmp_reg = self.alloc_reg();
                self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)group_reg, (uint)undef_reg);
                self.free_reg(undef_reg);

                uint skip_addr = self.code_count;
                self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                self.free_reg(cmp_reg);

                ushort closure_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, binds[di].default_func_idx);

                ushort call_base = self.alloc_reg();
                if (self.next_reg <= call_base + 1) { self.next_reg = call_base + 2; }
                self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                self.emit_abc(Opcode.LDREG, (uint)group_reg, (uint)call_base, 0);
                self.free_regs_to(call_base);

                int skip_off = (int)self.code_count - (int)skip_addr - 1;
                self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
            }

            // REQUIRE_OBJ — TypeError if null/undefined nested target.
            // Skip for rest synthetics (always an array).
            if (binds[di].key_idx != 0xFFFF) {
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)group_reg, 0, 0);
            }
        } else {
            // Leaf binding — a real variable.
            // Member-expression assignment targets (ASSIGN_TARGET) pass 0xFFFF
            // here rather than a pre-allocated register: the caller cannot know
            // where the persistent member_obj_reg/member_prop_reg/computed_key_reg
            // will land (allocated in the pre-scan above), and GETPROP's accessor
            // getter call frame is placed AT the result register (reusing it and
            // everything above), so bind_reg must be allocated *after* — i.e. at
            // a higher register number than — any live persistent register or
            // the getter call would clobber it. Allocate it fresh here instead.
            ushort bind_reg = binding_regs[di];
            if (bind_reg == 0xFFFF) {
                bind_reg = self.alloc_reg();
                binding_regs[di] = bind_reg;
            }
            uint ni = binds[di].name_idx;

            // Extract value from source into bind_reg
            if (binds[di].is_object) {
                if (binds[di].key_idx == 0xFFFF) {
                    // Object rest: `{...rest}` → Object.assign({}, src) minus siblings.
                    self.emit_object_rest(bind_reg, src_reg, binds, count, di);
                } else if (binds[di].is_computed_key) {
                    if (binds[di].deferred_computed_key != null) {
                        self.emit_deferred_computed_key(&binds[di]);
                    }
                    // Per ES2022 §13.15.5.6 KeyedDestructuringAssignmentEvaluation:
                    // 1. Evaluate target (lref) — get object + key reference.
                    // 2. GetV(value, propertyName) — read source property.
                    // 3. PutValue — assign (including brand check for private fields).
                    // So emit_deferred_target runs first, then GETPROP, then the
                    // deferred CHK_BRAND for private targets.
                    if (binds[di].deferred_target != null) {
                        self.emit_deferred_target(&binds[di]);
                    }
                    self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)binds[di].computed_key_reg);
                    // Deferred CHK_BRAND for private field targets: the brand check
                    // must run AFTER the source property is read (GetV), per spec.
                    if (binds[di].is_private_target) {
                        self.emit_abc(Opcode.CHK_BRAND, (uint)binds[di].private_brand_obj_reg, (uint)binds[di].private_brand_reg, binds[di].private_brand_name_c);
                        self.free_reg(binds[di].private_brand_reg);
                    }
                } else {
                    if (binds[di].deferred_target != null) {
                        self.emit_deferred_target(&binds[di]);
                    }
                    ushort key_reg = self.alloc_reg();
                    self.emit_a_bc(Opcode.LDCONST, (uint)key_reg, binds[di].key_idx);
                    self.emit_abc(Opcode.GETPROP, (uint)bind_reg, (uint)src_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                    // Deferred CHK_BRAND for private field targets: the brand check
                    // must run AFTER the source property is read (GetV), per spec.
                    if (binds[di].is_private_target) {
                        self.emit_abc(Opcode.CHK_BRAND, (uint)binds[di].private_brand_obj_reg, (uint)binds[di].private_brand_reg, binds[di].private_brand_name_c);
                        self.free_reg(binds[di].private_brand_reg);
                    }
                }
            } else {
                if (binds[di].key_idx == 0xFFFF) {
                    // Rest element: collect remaining iterator values into a new array.
                    // Use bind_reg (pre-allocated low register from declare_var)
                    // directly for the array to avoid the CALL callee-frame overlay
                    // (CALL places callee frame at callee_reg+2, which would
                    // clobber a freshly allocated register).
                    self.emit_abc(Opcode.NEWARR, (uint)bind_reg, 0, 0);

                    ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
                    if (iter_idx == 0xFFFF) {
                        iter_idx = (ushort)iter_count;
                        iter_count++;
                        self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
                    }
                    DestructIterState* state = &iter_states[iter_idx];

                    // Emit the deferred rest member-target evaluation now — AFTER
                    // the iterator is opened but BEFORE collection — so a throw from
                    // a side-effecting target (e.g. `...{}[thrower()]`) triggers
                    // IteratorClose on the open iterator (ES2022 §13.15.5.3).
                    if (binds[di].deferred_target != null) {
                        self.emit_deferred_target(&binds[di]);
                    }

                    ushort result_reg = self.alloc_reg();
                    ushort done_key_reg = self.alloc_reg();
                    ushort done_reg = self.alloc_reg();

                    uint collect_start = self.code_count;

                    self.emit_abc(Opcode.LDREG, (uint)state.callee_reg, (uint)state.next_reg, 0);
                    self.emit_abc(Opcode.LDREG, (uint)state.callee_this_reg, (uint)state.method_reg, 0);

                    // Latch [[done]] across .next()/.done/.value: a throw sets
                    // [[Done]] before rethrowing, so the enclosing finally must
                    // NOT IteratorClose for it (§7.4.6/§7.4.8). Park the iterator
                    // in save_reg and clear method_reg; restore on a good step.
                    self.emit_abc(Opcode.LDREG, (uint)state.save_reg, (uint)state.method_reg, 0);
                    self.emit_abc(Opcode.LDUNDEF, (uint)state.method_reg, 0, 0);

                    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)state.callee_reg, 0);

                    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
                    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
                    uint done_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

                    ushort val_key_reg = self.alloc_reg();
                    ushort val_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDCONST, (uint)val_key_reg, self.add_string_constant("value"), 0);
                    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)val_key_reg);
                    self.free_reg(val_key_reg);
                    // Good not-done step: restore the live iterator for close.
                    self.emit_abc(Opcode.LDREG, (uint)state.method_reg, (uint)state.save_reg, 0);

                    ushort push_key_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDCONST, (uint)push_key_reg, self.add_string_constant("push"), 0);
                    ushort push_method_reg = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP, (uint)push_method_reg, (uint)bind_reg, (uint)push_key_reg);
                    self.free_reg(push_key_reg);

                    ushort push_callee_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDREG, (uint)push_callee_reg, (uint)push_method_reg, 0);
                    self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 1), (uint)bind_reg, 0);
                    if (self.next_reg < push_callee_reg + 3) {
                        self.next_reg = push_callee_reg + 3;
                    }
                    self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 2), (uint)val_reg, 0);
                    self.free_reg(val_reg);
                    self.free_reg(push_method_reg);
                    self.emit_abc(Opcode.CALL, (uint)push_callee_reg, (uint)push_callee_reg, 1);
                    self.free_reg(push_callee_reg);

                    int back_offset = (int)collect_start - (int)self.code_count - 1;
                    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));
                    self.patch_jump(done_jump);
                    // Rest consumed the iterator to done:true — latch [[done]] so
                    // the trailing IteratorClose is skipped (§13.3.3.8 step 4.b),
                    // matching the synthetic-rest path. Without this, ITER_CLOSE
                    // calls .return() on an already-done iterator.
                    self.emit_abc(Opcode.LDUNDEF, (uint)iter_states[iter_idx].method_reg, 0, 0);

                    self.free_reg(done_key_reg);
                    self.free_reg(done_reg);
                    self.free_reg(result_reg);
                } else {
                    // Array pattern: use iterator protocol
                    ushort iter_idx = find_destruct_iter(src_reg, iter_states[..], &iter_count);
                    if (iter_idx == 0xFFFF) {
                        iter_idx = (ushort)iter_count;
                        iter_count++;
                        self.emit_destruct_iter_setup(src_reg, &iter_states[iter_idx]);
                    }
                    // Emit the deferred member-target evaluation BEFORE
                    // IteratorStep, per ES2022 §13.15.5.6: the target lref is
                    // evaluated before IteratorStep, so any throw here triggers
                    // IteratorClose on the already-opened inner iterator.
                    if (binds[di].deferred_target != null) {
                        self.emit_deferred_target(&binds[di]);
                    }
                    self.emit_destruct_iter_next(&iter_states[iter_idx], bind_reg);
                }
            }

            // Default value check: if bind_reg is undefined, use the default thunk
            if (binds[di].has_default) {
                ushort undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
                ushort cmp_reg = self.alloc_reg();
                self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)bind_reg, (uint)undef_reg);
                self.free_reg(undef_reg);

                uint skip_addr = self.code_count;
                self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
                self.free_reg(cmp_reg);

                ushort closure_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, binds[di].default_func_idx);

                ushort call_base = self.alloc_reg();
                if (self.next_reg <= call_base + 1) { self.next_reg = call_base + 2; }
                self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
                self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
                self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
                self.emit_abc(Opcode.LDREG, (uint)bind_reg, (uint)call_base, 0);
                self.free_regs_to(call_base);

                int skip_off = (int)self.code_count - (int)skip_addr - 1;
                self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
            }

            // Sync binding to environment per store mode (see DestructStoreMode).
            switch (store_mode) {
                case PARAM_SYNC:
                    self.emit_a_bc(Opcode.PUTVAR, (uint)bind_reg, ni);
                    self.emit_a_bc(Opcode.GETVAR, (uint)bind_reg, ni);
                case DECLARE:
                    self.emit_var_store(bind_reg, ni, is_lexical, is_const);
                case ASSIGN_TARGET:
                    // Member-expression targets (e.g. [obj.x] = v) use PUTPROP
                    // rather than PUTVAR. The deferred target evaluation code was
                    // already re-emitted before IteratorStep (ES2022 §13.15.5.6),
                    // so here we just do the assignment. For private member
                    // targets, the brand check was deferred and must run AFTER
                    // the value has been extracted into bind_reg, matching the
                    // object-pattern code path's structure (see emit_deferred_target
                    // — it set is_private_target during the earlier emit).
                    if (binds[di].is_member_target) {
                        if (binds[di].is_private_target) {
                            self.emit_abc(Opcode.CHK_BRAND,
                                (uint)binds[di].private_brand_obj_reg,
                                (uint)binds[di].private_brand_reg,
                                binds[di].private_brand_name_c);
                            self.free_reg(binds[di].private_brand_reg);
                        }
                        self.emit_abc(Opcode.PUTPROP,
                            (uint)binds[di].member_obj_reg,
                            (uint)binds[di].member_prop_reg,
                            (uint)bind_reg);
                        self.free_reg(binds[di].member_prop_reg);
                        self.free_reg(binds[di].member_obj_reg);
                    } else if (binds[di].assign_needs_putvar || !self.is_local_var_reg(bind_reg)) {
                        // Destructuring assignment target — throws on TDZ let/const.
                        self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)bind_reg, ni);
                    }
            }
        }
    }

    // Close the TRY guard and emit the IteratorClose finally block.
    //
    // IteratorClose must run on EVERY abrupt completion of the destructuring —
    // not just throw, but also a `return` completion (e.g. a generator `.return()`
    // resuming a `yield` inside a target lref such as `[...{}[yield]]`) and
    // break/continue. A catch-only handler fires on throw alone, so the guard is
    // lowered as a try/FINALLY: the finally runs ITER_CLOSE for each iterator and
    // ENDFINALLY then re-dispatches the pending completion (throw/return/break/
    // continue/normal). On the normal path the finally still runs, which also
    // covers §13.15.5.3 "if [[done]] is false, IteratorClose" for a
    // partially-consumed iterator — so no separate normal-path close is needed.
    if (iter_try_addr != 0xFFFFFFFF && iter_count > 0) {
        // Normal path: end the try region, then fall through to the finally.
        // (The jump slot's finally offset also routes abrupt completions here.)
        self.emit_simple(Opcode.ENDTRY);

        // FINALLY block — entered on normal completion (fall-through) and on any
        // abrupt completion (via the catcher's finally_pc).
        uint finally_target = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        for (uint i = 0; i < iter_count; i++) {
            // B=2: auto-detect completion type — suppress .return() errors only
            // when the pending completion is a throw (§7.4.6 steps 6/8); a return
            // completion (e.g. generator .return() through a yield here) must
            // propagate a throwing/non-object .return().
            self.emit_abc(Opcode.ITER_CLOSE, (uint)iter_states[i].method_reg, 2, 0);
        }
        self.emit_simple(Opcode.ENDFINALLY);

        // Patch TRY: flags = finally (bit1). Jump slot BC = finally offset.
        self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 2, 0);
        uint finally_off = finally_target - iter_try_addr;
        self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);
    } else if (iter_try_addr != 0xFFFFFFFF) {
        // TRY was emitted but no iterators were set up (unusual: pure object binds
        // after the pre-scan flag — should not happen, but be safe).
        self.emit_simple(Opcode.ENDTRY);
        uint finally_target_e = self.code_count;
        self.emit_simple(Opcode.FINALLY);
        self.emit_simple(Opcode.ENDFINALLY);
        self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 2, 0);
        uint finally_off_e = finally_target_e - iter_try_addr;
        self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off_e);
    }

    // Free iterator registers. IteratorClose already ran in the finally above.
    for (uint i = 0; i < iter_count; i++) {
        self.free_destruct_iter(&iter_states[i]);
    }
}

/// Skip past a braced block in the lexer without compiling.
/// Assumes the lexer is positioned just after '{'. Advances past matching '}'.
/// Template-aware: a '}' that closes a template substitution is consumed via
/// scan_template_after_expr() and never counted as a plain RBRACE.
fn void CompilerContext.skip_braced_block(&self) {
    uint brace_depth = 1;
    uint template_depth = 0; // open template substitution levels
    while (brace_depth > 0) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) break;
        if (tt == TokenType.LBRACE) {
            brace_depth++;
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            // Entering a template substitution: the scanner consumed `...${
            // and the next tokens are the substitution expression.
            template_depth++;
        } else if (tt == TokenType.RBRACE) {
            if (template_depth > 0) {
                // This RBRACE closes a template substitution, not a JS block.
                // Consume the following template part (middle or tail).
                Token? part_opt = self.lexer.scan_template_after_expr();
                if (catch _err2 = part_opt) break;
                if (part_opt.type == TokenType.TEMPLATE_MIDDLE) {
                    // Another substitution follows; template_depth stays the same.
                } else {
                    // TEMPLATE_TAIL: this template literal is done.
                    template_depth--;
                }
            } else {
                brace_depth--;
            }
        }
    }
}

/// Skip past a full class declaration/expression, starting with the lexer
/// positioned just after the `class` keyword. Consumes the optional binding
/// name, an optional `extends <LeftHandSideExpression>`, and the class body
/// `{ ... }`. A class body is its own scope for VarDeclaredNames — none of
/// its element bodies (methods, accessors, static blocks, field
/// initializers) contribute `var`/`function` declarations to the enclosing
/// function or Program scope — so hoist_decls must skip it wholesale rather
/// than brace-walk into a method and mis-hoist that method's locals.
fn void CompilerContext.skip_class_body(&self) {
    // Advance to the class body's opening '{', which is the first LBRACE at
    // paren/bracket depth 0. The heading before it (name, `extends expr`)
    // may itself contain parens/brackets (e.g. `extends f(a[0])`) whose
    // braces must not be mistaken for the body opener.
    uint paren_depth = 0;
    uint bracket_depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LPAREN) { paren_depth++; }
        else if (tt == TokenType.RPAREN) { if (paren_depth > 0) paren_depth--; }
        else if (tt == TokenType.LBRACKET) { bracket_depth++; }
        else if (tt == TokenType.RBRACKET) { if (bracket_depth > 0) bracket_depth--; }
        else if (tt == TokenType.LBRACE && paren_depth == 0 && bracket_depth == 0) {
            // Found the class body's opening brace — skip the balanced body.
            self.skip_braced_block();
            return;
        }
    }
}

/// Skip past a full function declaration body starting from '('.
/// Consumes '(' params ')' '{' body '}'.
/// Template-aware: a '}' that closes a template substitution is consumed via
/// scan_template_after_expr() and never counted as a plain RBRACE.
fn void CompilerContext.skip_function_body(&self) {
    // Skip '(' ... ')'
    // Template literals cannot appear in parameter lists so no template
    // tracking is needed here.
    uint paren_depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LPAREN) { paren_depth++; }
        else if (tt == TokenType.RPAREN) {
            paren_depth--;
            if (paren_depth == 0) break; // found the matching ')'
        }
    }
    // Skip '{' ... '}', tracking template substitution depth so that a '}'
    // closing a '${' does not prematurely end the function-body scan.
    uint brace_depth = 0;
    uint template_depth = 0; // open template substitution levels
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LBRACE) {
            brace_depth++;
        } else if (tt == TokenType.TEMPLATE_HEAD) {
            // Entering a template substitution: the scanner consumed `...${
            // and the next tokens are the substitution expression.
            template_depth++;
        } else if (tt == TokenType.RBRACE) {
            if (template_depth > 0) {
                // This RBRACE closes a template substitution, not a JS block.
                // Consume the following template part (middle or tail).
                Token? part_opt = self.lexer.scan_template_after_expr();
                if (catch _err2 = part_opt) return;
                if (part_opt.type == TokenType.TEMPLATE_MIDDLE) {
                    // Another substitution follows; template_depth stays the same.
                } else {
                    // TEMPLATE_TAIL: this template literal is done.
                    template_depth--;
                }
            } else {
                brace_depth--;
                if (brace_depth == 0) break; // found matching '}'
            }
        }
    }
}

/// Skip past a single destructuring pattern (`{...}` or `[...]`), handling
/// arbitrarily nested `{}`/`[]` of either kind. The opening token has
/// already been consumed by the caller; this advances the lexer to just
/// past the matching closing token.
fn void CompilerContext.skip_destructure_pattern(&self) {
    int depth = 1;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) return;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) return;
        if (tt == TokenType.LBRACE || tt == TokenType.LBRACKET) {
            depth++;
        } else if (tt == TokenType.RBRACE || tt == TokenType.RBRACKET) {
            depth--;
            if (depth == 0) return;
        }
    }
}

/// Scan forward through a destructured parameter pattern from the current
/// lexer position to find the matching closing ')' and check if '=>' follows.
/// Returns true if this is an arrow function with destructured params.
/// Assumes the outer '(' has already been consumed and the lexer is positioned
/// at the start of the destructuring pattern ({ or [).
fn bool CompilerContext.scan_destruct_param_to_arrow(&self) {
    int paren_d = 1;   // outer '(' already consumed
    int brace_d = 0;
    int bracket_d = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) { break; }
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) { break; }
        if (tt == TokenType.LPAREN) { paren_d++; }
        else if (tt == TokenType.RPAREN) {
            paren_d--;
            if (paren_d == 0) {
                return self.check(TokenType.ARROW);
            }
        }
        else if (tt == TokenType.LBRACE) { brace_d++; }
        else if (tt == TokenType.RBRACE) { brace_d--; }
        else if (tt == TokenType.LBRACKET) { bracket_d++; }
        else if (tt == TokenType.RBRACKET) { bracket_d--; }
    }
    return false;
}

/// Skip past an arbitrary expression in the lexer without compiling.
/// Tracks paren, brace, and bracket depth.
fn void CompilerContext.skip_expression(&self) {
    uint paren_depth = 0;
    uint brace_depth = 0;
    uint bracket_depth = 0;
    uint template_depth = 0; // open template substitution levels
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;
        if (tt == TokenType.EOF_TOKEN) break;
        if (tt == TokenType.LPAREN) { paren_depth++; }
        else if (tt == TokenType.RPAREN) {
            if (paren_depth == 0 && brace_depth == 0 && bracket_depth == 0
                && template_depth == 0) {
                // This closing paren belongs to the caller — push back
                self.lexer.pushback(tok_opt);
                break;
            }
            if (paren_depth > 0) paren_depth--;
        }
        else if (tt == TokenType.LBRACE) { brace_depth++; }
        else if (tt == TokenType.TEMPLATE_HEAD) {
            // Template substitution open: the lexer consumed `...${
            template_depth++;
        }
        else if (tt == TokenType.RBRACE) {
            if (template_depth > 0) {
                // This RBRACE closes a template substitution.
                Token? part_opt = self.lexer.scan_template_after_expr();
                if (catch _err2 = part_opt) break;
                if (part_opt.type == TokenType.TEMPLATE_MIDDLE) {
                    // Another substitution: template_depth stays the same.
                } else {
                    // TEMPLATE_TAIL or error: template literal is done.
                    template_depth--;
                }
            } else {
                if (brace_depth == 0 && bracket_depth == 0 && paren_depth == 0) break;
                if (brace_depth > 0) brace_depth--;
            }
        }
        else if (tt == TokenType.LBRACKET) { bracket_depth++; }
        else if (tt == TokenType.RBRACKET) {
            if (bracket_depth > 0) bracket_depth--;
        }
        else if (paren_depth == 0 && brace_depth == 0 && bracket_depth == 0
                 && template_depth == 0) {
            // At top level: break on comma, semicolon, EOF
            if (tt == TokenType.COMMA || tt == TokenType.SEMICOLON) {
                self.lexer.pushback(tok_opt);
                break;
            }
        }
    }
}

/// Pre-scan function body for var and function declarations and emit hoisted
/// bytecode so they are available before any statements run.
fn void? CompilerContext.hoist_decls(&self, bool is_global, bool checks_only = false) {
    // self.is_async doubles as the "saw `async function`" latch between loop
    // iterations below. It must start clear — otherwise, inside an async
    // function's body, the enclosing flag would mark every hoisted plain
    // `function` declaration as async — and the enclosing function's flag
    // must survive this pass (it is read by finish() when the enclosing
    // body's compilation completes).
    bool enclosing_is_async = self.is_async;
    self.is_async = false;
    defer self.is_async = enclosing_is_async;

    // --- Save lexer state (for final restore) ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    uint brace_depth = 0;
    // For a global/module-level scan, the lexer starts at the Program's own
    // top level (no enclosing brace to consume), so top-level declarations
    // sit at brace_depth 0. For a function-local scan, the lexer starts
    // *before* the function body's own opening '{' (hoist_decls runs prior
    // to CompilerContext.block(), which consumes it) — that '{' is the
    // first LBRACE this scan sees, so declarations at the top of the
    // function body sit at brace_depth 1, not 0.
    uint own_depth = is_global ? 0 : 1;
    // Template substitution depth: incremented on TEMPLATE_HEAD/MIDDLE,
    // decremented on TEMPLATE_TAIL.  A RBRACE when template_depth > 0 closes
    // a template substitution and must not be treated as a JS block boundary.
    uint template_depth = 0;
    // Byte offset of the `function` keyword when preceded by `async` at
    // brace_depth 0. The async-detection branch below pushes `function`
    // back so it's re-scanned on the *next* loop iteration — but pushback
    // does not rewind lexer.pos, so that iteration's `pos_before` snapshot
    // no longer points at `function`'s start. Stash the true offset here so
    // the FUNCTION-handling branch can use it for source-text retention.
    uint pending_async_fn_kw_pos = 0xFFFFFFFF;

    while (true) {
        // Save lexer state before consuming this token (so we can restore
        // and re-consume it for function compilation).
        uint pos_before = self.lexer.pos;
        uint line_before = self.lexer.line;
        uint col_before = self.lexer.col;
        Token cur_before = self.lexer.current;
        Token look_before = self.lexer.lookahead;
        bool haslk_before = self.lexer.has_lookahead;
        Token push_before = self.lexer.pushed_back;
        bool haspb_before = self.lexer.has_pushed_back;
        bool slt_before = self.lexer.seen_line_term;

        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }
        // TEMPLATE_HEAD opens a template substitution: the lexer already
        // consumed the opening backtick through `${`; the expression tokens
        // follow, then a RBRACE that must be consumed by scan_template_after_expr.
        if (tt == TokenType.TEMPLATE_HEAD) {
            template_depth++;
            continue;
        }
        if (tt == TokenType.RBRACE) {
            if (template_depth > 0) {
                // This RBRACE closes a template substitution, not a JS block.
                Token? part_opt = self.lexer.scan_template_after_expr();
                if (catch _err2 = part_opt) break;
                if (part_opt.type == TokenType.TEMPLATE_MIDDLE) {
                    // Another substitution follows; template_depth stays the same.
                } else {
                    // TEMPLATE_TAIL: this template literal is complete.
                    template_depth--;
                }
                continue;
            }
            if (!is_global && brace_depth == 0) break;
            if (brace_depth > 0) brace_depth--;
            // For function-level hoisting, stop when the function body's
            // closing '}' returns brace_depth to 0 (end of scanned scope).
            if (!is_global && brace_depth == 0) break;
            continue;
        }

        // Detect `async function` at the scan's own top level: the pre-scan
        // sees IDENTIFIER("async") first, peeks at FUNCTION, and if so
        // pushes "function" back so the next iteration handles it as a
        // FUNCTION token with is_async already set.
        if (brace_depth == own_depth && tt == TokenType.IDENTIFIER &&
            tok_opt.str_value.len == 5 &&
            tok_opt.str_value[0] == 'a' && tok_opt.str_value[1] == 's' &&
            tok_opt.str_value[2] == 'y' && tok_opt.str_value[3] == 'n' &&
            tok_opt.str_value[4] == 'c') {
            Token? async_peek = self.lexer.next_token();
            if (catch _err_peek = async_peek) continue;
            if (async_peek.type == TokenType.FUNCTION) {
                // "async" consumed; push "function" back for the next iteration.
                // Capture its true source offset now — pushback does not
                // rewind lexer.pos, so the next iteration's `pos_before`
                // would otherwise point past `function` (see
                // pending_async_fn_kw_pos declaration above).
                pending_async_fn_kw_pos = self.lexer.token_start;
                {
                    Token fn_tok = async_peek;
                    self.lexer.pushback(fn_tok);
                }
                self.is_async = true;
                continue;
            }
            // Not followed by function — push back the peeked token
            {
                Token async_tok = async_peek;
                self.lexer.pushback(async_tok);
            }
        }

        if (tt == TokenType.CLASS) {
            // A class body is its own VarDeclaredNames scope — skip it whole
            // so a method/field-initializer's `var` locals never leak into
            // this scope. This applies at any depth the scan reaches (a class
            // at the scope's top level, or one nested in an if/for/try block);
            // class bodies inside a nested function are already unreachable
            // here because that function was skipped wholesale above.
            self.skip_class_body();
            continue;
        }

        // A `function` nested inside a block (if/for/try/plain `{}`) at global
        // scope — a function expression (`x = function(){ var y }`) or a
        // block-scoped function declaration — is its own VarDeclaredNames
        // scope. Skip its body wholesale so its inner `var`s don't leak into
        // the Program's global scope. (At own_depth the handler below does the
        // hoist-aware skip; deeper functions only need to be skipped.)
        if (is_global && brace_depth > own_depth && tt == TokenType.FUNCTION) {
            self.is_async = false;
            Token? nstar = self.lexer.next_token();
            if (catch _errn = nstar) continue;
            if (nstar.type != TokenType.STAR) { self.lexer.pushback(nstar); }
            Token? nname = self.lexer.next_token();
            if (catch _errn2 = nname) continue;
            if (nname.type != TokenType.IDENTIFIER) { self.lexer.pushback(nname); }
            self.skip_function_body();
            continue;
        }

        if (brace_depth == own_depth && tt == TokenType.FUNCTION) {
            // At global/module scope, function declarations are already hoisted
            // by hoist_global_fn_decls().  Skip them here to avoid double
            // compilation — just advance past the star, name, and body.
            if (is_global) {
                self.is_async = false;
                // Consume optional generator star
                Token? skip_star = self.lexer.next_token();
                if (catch _err_skip = skip_star) continue;
                if (skip_star.type == TokenType.STAR) {
                    // Star consumed; next token is the name
                } else {
                    // Not a star — push back (it's the name)
                    self.lexer.pushback(skip_star);
                }
                // Consume function name
                Token? skip_name = self.lexer.next_token();
                if (catch _err_skip2 = skip_name) continue;
                if (skip_name.type != TokenType.IDENTIFIER) {
                    // Anonymous function expression — push the token back so
                    // skip_function_body sees the full `function (...) { ... }`.
                    // For example in `(function() { ... }())`, the `(` is the
                    // function's param-open; we must leave it for the skipper.
                    self.lexer.pushback(skip_name);
                }
                // skip_function_body expects lexer past the name — skip (params) { body }
                self.skip_function_body();
                continue;
            }
            // If we detected `async function` above, is_async is already true.
            bool hoist_is_async = self.is_async;
            self.is_async = false;
            // Check for generator star
            Token? star_opt = self.lexer.next_token();
            if (catch _err2 = star_opt) continue;
            if (star_opt.type != TokenType.STAR) {
                // Not a star — put it back (it's the function name)
                self.lexer.pushback(star_opt);
            }
            Token? name_opt = self.lexer.next_token();
            if (catch _err = name_opt) break;
            if (name_opt.type != TokenType.IDENTIFIER) {
                // Anonymous function expression (e.g. an IIFE) — not a
                // declaration, so its `var`s belong to its own scope, not
                // this one. Push back the token (the param-list '(') so
                // skip_function_body sees the full `(...) { ... }` and
                // scans past the entire body instead of letting the
                // enclosing loop wander into it brace-by-brace and
                // mis-hoist its locals into this scope.
                self.lexer.pushback(name_opt);
                self.skip_function_body();
                continue;
            }

            char[] fn_name = name_opt.str_value;
            if (fn_name.len == 0) continue;

            // Check if already hoisted
            bool already = false;
            for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                    already = true;
                    break;
                }
            }
            if (already) {
                // Skip the rest of the function body
                self.skip_function_body();
                continue;
            }

            // Record as hoisted
            if (self.hoisted_fn_count < 256) {
                self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
                self.hoisted_fn_count++;
            }

            // Restore lexer to before 'function' so we can re-consume it properly
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;

            // Re-consume 'function' (async was already consumed before restore)
            self.expect(TokenType.FUNCTION)!;
            // Byte offset of `function` keyword for Function.prototype.toString
            // source-text retention. For `async function`, `pos_before` (and
            // thus the re-consumed token's start) points past `function`'s
            // true start because the async-detection iteration's pushback
            // of `function` didn't rewind lexer.pos — use the offset
            // captured at detection time instead.
            uint hoist_fn1_src_start = hoist_is_async ? pending_async_fn_kw_pos : self.lexer.token_start;
            pending_async_fn_kw_pos = 0xFFFFFFFF;

            // Handle generator star
            bool saved_gen = self.is_generator;
            self.is_generator = false;
            if (self.match(TokenType.STAR)) {
                self.is_generator = true;
            }

            Token name_tok2 = self.expect(TokenType.IDENTIFIER)!;

            ushort func_reg = self.declare_var(name_tok2.str_value, VAR);
            self.has_local_bindings = true;

            // Regular function declarations are constructable per ES2015 §14.1.2.
            // Generator and async functions are never constructable.
            bool saved_is_constructable = self.is_constructable;
            self.is_constructable = !self.is_generator && !hoist_is_async;

            self.is_async = hoist_is_async;
            // Use the byte offset of `function` captured right after expect().
            CompiledFunction* inner = self.compile_inner_function(name_tok2.str_value, false, hoist_fn1_src_start)!;
            self.is_async = false;

            self.is_generator = saved_gen;
            self.is_constructable = saved_is_constructable;

            uint inner_idx = self.add_inner_func(inner);

            // Emit CLOSURE + DECLVAR
            self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
            uint name_idx = self.add_string_constant(name_tok2.str_value);
            self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);

            // Lexer is now past the function body. Continue scanning.
        } else if (tt == TokenType.VAR) {
            // var declarations hoist through nested blocks (if/for/try/plain
            // `{}`) to the enclosing function or Program/module scope —
            // only a nested FUNCTION body is a hoisting boundary, and those
            // are fully skipped above (skip_function_body) before their
            // contents are ever seen here, so no brace_depth guard is
            // needed to avoid leaking an inner function's own vars.
            for (;;) {
                Token? name_opt2 = self.lexer.next_token();
                if (catch _err = name_opt2) break;
                Token name_tok2 = name_opt2;
                if (name_tok2.type != TokenType.IDENTIFIER) break;

                // Check-prologue pass: emit CanDeclareGlobalVar for each
                // top-level var name (Script only) and skip its binding.
                if (checks_only) {
                    if (is_global && !self.is_module) {
                        uint chk_idx = self.add_string_constant(name_tok2.str_value);
                        self.emit_a_bc(Opcode.CHKGLOBALVAR, 0, chk_idx);
                    }
                    // Consume initializer / comma so the scan advances the same
                    // way the real pass does, without emitting any binding.
                    Token? sep_opt_c = self.lexer.next_token();
                    if (catch _errc = sep_opt_c) break;
                    TokenType sepc = sep_opt_c.type;
                    if (sepc == TokenType.ASSIGN) {
                        self.skip_expression();
                        Token? sep_opt_c2 = self.lexer.next_token();
                        if (catch _errc2 = sep_opt_c2) break;
                        if (sep_opt_c2.type != TokenType.COMMA) {
                            self.lexer.pushback(sep_opt_c2);
                            break;
                        }
                    } else if (sepc != TokenType.COMMA) {
                        self.lexer.pushback(sep_opt_c);
                        break;
                    }
                    continue;
                }

                ushort var_reg = self.declare_var(name_tok2.str_value, VAR);
                self.has_local_bindings = true;
                self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
                uint var_name_idx = self.add_string_constant(name_tok2.str_value);
                self.emit_a_bc(Opcode.DECLVAR, (uint)var_reg, var_name_idx);
                // At global scope, var bindings are env-resident (accessed via
                // GETVAR/PUTVAR); the register is only a temporary DECLVAR source.
                // Free it immediately so 500+ var declarations don't exhaust the
                // register file.  Non-global hoisting must keep the register alive
                // as the function's actual local-variable slot.
                if (is_global) { self.free_reg(var_reg); }

                // Check for initializer or comma
                Token? sep_opt = self.lexer.next_token();
                if (catch _err = sep_opt) break;
                TokenType sep = sep_opt.type;
                if (sep == TokenType.ASSIGN) {
                    self.skip_expression();
                    // skip_expression stops (and pushes back) at the next
                    // comma/semicolon without consuming it — re-check here
                    // so a subsequent declarator in the same `var` statement
                    // (`var x, y = 1, z;`) is not skipped.
                    Token? sep_opt2 = self.lexer.next_token();
                    if (catch _err2 = sep_opt2) break;
                    if (sep_opt2.type != TokenType.COMMA) {
                        self.lexer.pushback(sep_opt2);
                        break;
                    }
                } else if (sep != TokenType.COMMA) {
                    break;
                }
            }
        } else if (!is_global && brace_depth == 0) {
            // Top-level token that isn't a declaration (function/var) — the
            // remaining program is real code (statements). Restore the lexer
            // to before this token and stop pre-scanning; the main statement()
            // loop will parse it.
            // Only applied for function-level hoisting (is_global=false).
            // Global hoisting must scan the entire source for interspersed declarations.
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;
            break;
        }
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;
}

/// Pre-scan function declarations at the top level (global scope) and hoist them
/// before any statements are compiled. This implements function declaration
/// hoisting as per ES5 §10.2.1.1.
///
/// `checks_only`: emit just the GlobalDeclarationInstantiation CanDeclare
/// checks (CHKGLOBALFUNC) for each top-level function name and skip all
/// binding instantiation / inner compilation. Used for a Script's up-front
/// check prologue, which must precede every var/function/lexical binding so a
/// collision throws with no observable side effects (ES2015 §15.1.11).
fn void? CompilerContext.hoist_global_fn_decls(&self, bool checks_only = false) {
    // See hoist_decls: self.is_async is the between-iteration `async function`
    // latch; start it clear and restore the enclosing value (e.g. a module
    // body's top-level-await flag set by compile_module) on exit.
    bool enclosing_is_async = self.is_async;
    self.is_async = false;
    defer self.is_async = enclosing_is_async;

    // --- Save lexer state (for final restore) ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    uint brace_depth = 0;
    // Template substitution depth: incremented on TEMPLATE_HEAD, decremented
    // on TEMPLATE_TAIL.  A RBRACE when template_depth > 0 closes a template
    // substitution and must not be treated as a JS block boundary.
    uint template_depth = 0;
    // See hoist_decls' pending_async_fn_kw_pos for why this is needed: the
    // async-detection branch pushes `function` back without rewinding
    // lexer.pos, so the next iteration's `pos_before` no longer points at
    // `function`'s true start.
    uint pending_async_fn_kw_pos = 0xFFFFFFFF;

    // Track the previous top-level token to disambiguate
    // function declarations from function expressions in expressions like
    // `var x = function name() { ... }`.  A `function` keyword at
    // brace_depth 0 is a declaration only when preceded by a statement
    // terminator (`;`, `{`, `}`, or start-of-file).  After an operator
    // (`=`, `(`, `,`, `:`, `?`, etc.) the `function` is an expression
    // and must be skipped.
    TokenType prev_toplevel = TokenType.EOF_TOKEN;
    bool has_prev = false;

    while (true) {
        // Save lexer state before consuming this token (so we can restore
        // and re-consume it for function compilation).
        uint pos_before = self.lexer.pos;
        uint line_before = self.lexer.line;
        uint col_before = self.lexer.col;
        Token cur_before = self.lexer.current;
        Token look_before = self.lexer.lookahead;
        bool haslk_before = self.lexer.has_lookahead;
        Token push_before = self.lexer.pushed_back;
        bool haspb_before = self.lexer.has_pushed_back;
        bool slt_before = self.lexer.seen_line_term;

        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        TokenType tt = tok_opt.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }
        // TEMPLATE_HEAD opens a template substitution: the lexer consumed the
        // opening backtick through `${`; the expression tokens follow, then a
        // RBRACE that belongs to the template and not to any JS block.
        if (tt == TokenType.TEMPLATE_HEAD) {
            template_depth++;
            continue;
        }
        if (tt == TokenType.RBRACE) {
            if (template_depth > 0) {
                // This RBRACE closes a template substitution, not a JS block.
                Token? part_opt = self.lexer.scan_template_after_expr();
                if (catch _err2 = part_opt) break;
                if (part_opt.type == TokenType.TEMPLATE_MIDDLE) {
                    // Another substitution follows; template_depth stays the same.
                } else {
                    // TEMPLATE_TAIL: this template literal is complete.
                    template_depth--;
                    // A completed template at top level is like an expression — not a
                    // statement terminator, so leave prev_toplevel as-is.
                }
                continue;
            }
            brace_depth--;
            if (brace_depth == 0) {
                prev_toplevel = TokenType.RBRACE;
                has_prev = true;
            }
            continue;
        }

        // Detect `async function` at brace_depth 0
        if (brace_depth == 0 && tt == TokenType.IDENTIFIER &&
            tok_opt.str_value.len == 5 &&
            tok_opt.str_value[0] == 'a' && tok_opt.str_value[1] == 's' &&
            tok_opt.str_value[2] == 'y' && tok_opt.str_value[3] == 'n' &&
            tok_opt.str_value[4] == 'c') {
            Token? async_peek = self.lexer.next_token();
            if (catch _err_peek = async_peek) continue;
            if (async_peek.type == TokenType.FUNCTION) {
                // Capture `function`'s true source offset before pushing it
                // back — pushback does not rewind lexer.pos.
                pending_async_fn_kw_pos = self.lexer.token_start;
                {
                    Token fn_tok = async_peek;
                    self.lexer.pushback(fn_tok);
                }
                self.is_async = true;
                continue;
            }
            {
                Token async_tok = async_peek;
                self.lexer.pushback(async_tok);
            }
        }

        if (brace_depth == 0 && tt == TokenType.SEMICOLON) {
            prev_toplevel = TokenType.SEMICOLON;
            has_prev = true;
            continue;
        }

        if (brace_depth == 0 && tt == TokenType.FUNCTION) {
            // `function` at brace_depth 0 is a declaration only when it
            // starts a statement.  In expression position (after `=`,
            // `(`, `,`, `:`, `?`, `=>`, etc.) it must be skipped to
            // avoid double-compilation by the statement parser.
            bool in_stmt_pos = !has_prev
                || prev_toplevel == TokenType.SEMICOLON
                || prev_toplevel == TokenType.RBRACE
                || prev_toplevel == TokenType.LBRACE
                || prev_toplevel == TokenType.EOF_TOKEN;
            if (!in_stmt_pos) {
                // Expression position — skip the entire function expression
                // body so we don't compile it here.  The statement parser
                // will see the `function` token on the second pass.
                // Clear any is_async latched by the `async function` detection
                // above — this function is being skipped, so the flag must not
                // leak into later declarations in the scan.
                self.is_async = false;
                self.skip_function_body();
                prev_toplevel = TokenType.FUNCTION;
                has_prev = true;
                continue;
            }
            bool hoist_is_async = self.is_async;
            self.is_async = false;
            // Check for generator star
            Token? star_opt = self.lexer.next_token();
            if (catch _err2 = star_opt) continue;
            if (star_opt.type != TokenType.STAR) {
                // Not a star — put it back (it's the function name)
                self.lexer.pushback(star_opt);
            }
            Token? name_opt = self.lexer.next_token();
            if (catch _err = name_opt) break;
            if (name_opt.type != TokenType.IDENTIFIER) continue;

            char[] fn_name = name_opt.str_value;
            if (fn_name.len == 0) continue;

            // Record as hoisted so the statement parser skips every like-named
            // declaration on its own pass. Every occurrence is still compiled
            // and emitted below: GlobalDeclarationInstantiation (§15.1.11 step
            // 10, reverse list order) makes the LAST FunctionDeclaration the
            // surviving one, so emitting a CLOSURE+DECLVAR per occurrence in
            // source order lets the final DECLVAR overwrite the earlier
            // global-object bindings at runtime.
            bool already = false;
            for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                    already = true;
                    break;
                }
            }
            if (!already && self.hoisted_fn_count < 256) {
                self.hoisted_fn_names[self.hoisted_fn_count] = fn_name;
                self.hoisted_fn_count++;
            }

            // Check-prologue pass: emit CanDeclareGlobalFunction for each
            // unique top-level function name (Script only) and skip the body.
            if (checks_only) {
                if (!already && self.is_global && !self.is_module) {
                    uint chk_idx = self.add_string_constant(fn_name);
                    self.emit_a_bc(Opcode.CHKGLOBALFUNC, 0, chk_idx);
                }
                self.skip_function_body();
                prev_toplevel = TokenType.RBRACE;
                has_prev = true;
                continue;
            }

            // Restore lexer to before 'function' so we can re-consume it properly
            self.lexer.pos             = pos_before;
            self.lexer.line            = line_before;
            self.lexer.col             = col_before;
            self.lexer.current         = cur_before;
            self.lexer.lookahead       = look_before;
            self.lexer.has_lookahead   = haslk_before;
            self.lexer.pushed_back     = push_before;
            self.lexer.has_pushed_back = haspb_before;
            self.lexer.seen_line_term  = slt_before;

            // Re-consume 'function' (async was already consumed before restore)
            self.expect(TokenType.FUNCTION)!;
            // Byte offset of `function` keyword for Function.prototype.toString
            // source-text retention. For `async function`, `pos_before` (and
            // thus the re-consumed token's start) points past `function`'s
            // true start because the async-detection iteration's pushback
            // of `function` didn't rewind lexer.pos — use the offset
            // captured at detection time instead.
            uint hoist_fn1_src_start = hoist_is_async ? pending_async_fn_kw_pos : self.lexer.token_start;
            pending_async_fn_kw_pos = 0xFFFFFFFF;

            // Handle generator star
            bool saved_gen = self.is_generator;
            self.is_generator = false;
            if (self.match(TokenType.STAR)) {
                self.is_generator = true;
            }

            Token name_tok2 = self.expect(TokenType.IDENTIFIER)!;

            ushort func_reg = self.declare_var(name_tok2.str_value, VAR);
            self.has_local_bindings = true;

            // Regular function declarations are constructable per ES2015 §14.1.2.
            // Generator and async functions are never constructable.
            bool saved_is_constructable = self.is_constructable;
            self.is_constructable = !self.is_generator && !hoist_is_async;

            self.is_async = hoist_is_async;
            // Use the byte offset of `function` captured right after expect().
            CompiledFunction* inner = self.compile_inner_function(name_tok2.str_value, false, hoist_fn1_src_start)!;
            self.is_async = false;

            self.is_generator = saved_gen;
            self.is_constructable = saved_is_constructable;

            uint inner_idx = self.add_inner_func(inner);

            // In a module, top-level function declarations are instantiated
            // during InitializeEnvironment (ECMA-262 16.2.1.5.5 step 17): the
            // linker creates each closure once, before ANY module body runs,
            // so cyclic early imports observe the hoisted function and its
            // identity stays stable across evaluation. Record the declaration
            // for the linker and DO NOT emit body-level CLOSURE+DECLVAR — that
            // would re-instantiate a fresh closure on every evaluation and
            // change the export's identity. Scripts (non-module) keep the
            // in-body instantiation below.
            if (self.is_module && self.current_module != null) {
                mod_register_func_decl(self.get_module_def(), name_tok2.str_value, inner_idx);
                self.free_reg(func_reg);
                prev_toplevel = TokenType.RBRACE;
                has_prev = true;
                continue;
            }

            // Emit CLOSURE + DECLVAR
            self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);
            uint name_idx = self.add_string_constant(name_tok2.str_value);
            self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);
            // Global function declarations: func_reg is env-resident; free the
            // temporary register so repeated hoisting doesn't exhaust the file.
            self.free_reg(func_reg);

            // Lexer is now past the function body. A completed declaration
            // ends at its `}`, so record RBRACE (a statement terminator) —
            // the next top-level `function` starts a new declaration.
            prev_toplevel = TokenType.RBRACE;
            has_prev = true;
            continue;
        }

        // For other top-level tokens, record the operator so the next
        // `function` (if any) is recognized as an expression.  Any token
        // that is not a statement terminator (`;`, `{`, `}`) puts the
        // following `function` in expression position.
        if (brace_depth == 0 && tt != TokenType.SEMICOLON
            && tt != TokenType.LBRACE && tt != TokenType.RBRACE
            && tt != TokenType.EOF_TOKEN) {
            prev_toplevel = tt;
            has_prev = true;
        }
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;
}

/// Parse function body (parameters and block) and compile into a nested context.
fn void? CompilerContext.parse_function_body(&self, bool is_expr) {
    // Parse parameter list
    self.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Track seen param names for duplicate-param rejection (strict mode ES5 §13.1,
    // strict-only engine). Each entry stores name bytes; comparison is byte-wise.
    char[64][MAX_PARAMS] seen_param_names;
    ushort[MAX_PARAMS]    seen_param_lens;
    uint seen_param_count = 0;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] destruct_binds;
    uint destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] destruct_group_regs;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...[]
                if (self.check(TokenType.LBRACE)) {
                    self.advance()!;
                    self.alloc_reg();
                    self.collect_obj_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {}; // mark as destructured
                } else if (self.check(TokenType.LBRACKET)) {
                    self.advance()!;
                    self.alloc_reg();
                    self.collect_arr_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = self.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    if (is_restricted_name(rest_param.str_value)) {
                        return COMPILE_ERROR~;
                    }
                    if (check_dup_param(rest_param.str_value, seen_param_names[..], seen_param_lens[..], seen_param_count)) {
                        return COMPILE_ERROR~;
                    }
                    if (seen_param_count < MAX_PARAMS && rest_param.str_value.len < 64) {
                        for (usz k = 0; k < rest_param.str_value.len; k++) {
                            seen_param_names[seen_param_count][k] = rest_param.str_value[k];
                        }
                        seen_param_lens[seen_param_count] = (ushort)rest_param.str_value.len;
                        seen_param_count++;
                    }
                    ushort rest_reg = self.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = self.add_string_constant(rest_param.str_value);
                    self.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                self.has_rest = true;
                self.rest_formal_count = arg_count - 1;
                self.num_args = arg_count;
                self.formal_count = formal_count;
                // Rest parameter must be last
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (self.check(TokenType.LBRACE)) {
                self.advance()!;
                // Reserve the formal parameter register slot so the incoming
                // argument stays live through all destructuring extractions.
                self.alloc_reg();
                // Emit REQUIRE_OBJ to throw TypeError if null/undefined.
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                self.collect_obj_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RPAREN)) break;
                continue;
            } else if (self.check(TokenType.LBRACKET)) {
                self.advance()!;
                // Reserve the formal parameter register slot.
                self.alloc_reg();
                // Emit REQUIRE_OBJ to throw TypeError if null/undefined.
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                self.collect_arr_param_binds(destruct_binds[..], &destruct_count, (ushort)arg_count, 0xFFFF)!;
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            if (check_dup_param(param.str_value, seen_param_names[..], seen_param_lens[..], seen_param_count)) {
                return COMPILE_ERROR~;
            }
            if (seen_param_count < MAX_PARAMS && param.str_value.len < 64) {
                for (usz k = 0; k < param.str_value.len; k++) {
                    seen_param_names[seen_param_count][k] = param.str_value[k];
                }
                seen_param_lens[seen_param_count] = (ushort)param.str_value.len;
                seen_param_count++;
            }
            ushort param_reg = self.declare_var(param.str_value, VAR);
            uint param_name_idx = self.add_string_constant(param.str_value);
            arg_count++;

            // Check for default value
            if (self.check(TokenType.ASSIGN)) {
                self.advance()!; // consume '='

                // Compile the default expression as an inner function. Pass
                // the parameter name so NamedEvaluation tags an anonymous
                // fn/arrow/class/gen default with the param name.
                // (ES2015 §14.1.20 SetFunctionName.)
                CompiledFunction* default_func = self.compile_default_expr(param.str_value)!;

                // Add to inner functions table
                if (self.default_count < MAX_PARAMS) {
                    uint def_idx = self.add_inner_func(default_func);
                    self.defaults[self.default_count].param_reg = param_reg;
                    self.defaults[self.default_count].param_name_idx = param_name_idx;
                    self.defaults[self.default_count].default_func_idx = def_idx;
                    self.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            // Only increment formal_count if no default has been seen yet.
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // DECLVAR creates binding in var_env.
            self.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!self.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (self.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!self.has_rest) {
        self.num_args = arg_count;
    }
    self.formal_count = formal_count;

    self.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables.
    // Synthetics don't get variables — they're intermediate extraction points.
    for (uint i = 0; i < destruct_count; i++) {
        if (destruct_binds[i].is_synthetic) {
            destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = destruct_binds[i].name_idx;
        char[] name = destruct_binds[i].name_buf[:destruct_binds[i].name_len];
        ushort dreg = self.declare_var(name, VAR);
        destruct_binding_regs[i] = dreg;
        self.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }


    // Push a function-level lexical scope for let/const at function top level.
    // This sits above the block-level PUSH_LEX emitted by block() so that
    // function-level let/const go into a scope that outlives inner blocks.
    // Skip when there are no default parameters (the only case that needs
    // a function-level scope distinct from the block scope).
    bool has_func_lex = self.default_count > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            self.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            self.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < self.default_count; di++) {
        ushort pr = self.defaults[di].param_reg;
        uint name_idx = self.defaults[di].param_name_idx;
        uint func_idx = self.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = self.code_count;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        self.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = self.alloc_reg();
        if (self.next_reg <= call_base + 1) {
            self.next_reg = call_base + 2;
        }
        ushort this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Copy default result to parameter register.
        self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        self.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        // This ensures PUTVAR runs for BOTH branches (argument passed or default used).
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to lex scope first (clears TDZ sentinel), then var_env.
        // GETVAR reloads from env in case PUTVAR cleared it.
        self.emit_a_bc(Opcode.PUTLEX, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < self.default_count; di++) {
                if (self.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                self.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit destructuring code for destructured function parameters.
    self.emit_destruct_bindings(destruct_binds[..], destruct_count,
                                destruct_group_regs[..], destruct_binding_regs[..]);

    // Generator functions: emit GEN_START after all parameter initialization
    // so that the VM can run eagerly up to this point on the initial call,
    // satisfying the spec requirement that FunctionDeclarationInstantiation
    // (including throwing defaults/destructuring) happens at call time.
    if (self.is_generator && !self.is_async) {
        self.emit_simple(Opcode.GEN_START);
    }

    // Collect names captured by nested callables (plan 045) before any body
    // code is emitted, so declare_var can make them env-resident.
    self.pre_scan_captures();

    // Hoist var and function declarations to the top of the function scope.
    self.hoist_decls(false)!;

    // Params and hoisted slots are now allocated — pin them for the body.
    self.reserved_regs = self.next_reg;

    // Compile function body block. Function bodies parsed as expressions
    // (function expressions, method values, etc.) are not statement
    // boundaries: a `/` following the closing `}` continues the enclosing
    // expression as division, not a RegularExpressionLiteral. Suppress the
    // block-close regex hint in that case (see Lexer.note_block_close doc).
    self.block(true, is_expr)!;

    // Pop the function-level lexical scope.
    // NOTE: for functions with explicit return, this POP_LEX won't execute,
    // but that's harmless — the activation is destroyed on return.
    if (has_func_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    // Emit implicit return undefined if no explicit return
    // Check if last instruction is a return
    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        self.emit_simple((self.is_generator && !self.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }
}

/// Compile a default parameter expression as a zero-argument inner function.
/// Free variables in the expression are resolved at runtime via GETVAR
/// against the outer scope's environment chain.
fn CompiledFunction*? CompilerContext.compile_default_expr(&self, char[] inferred_name = {}) {
    // Create a new CompilerContext for the default expression
    CompilerContext def_ctx;
    def_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    def_ctx.lexer.set_strict(true);

    // Propagate generator context so yield is accepted inside default
    // expressions of generator functions (e.g. [x = yield] = []).
    // The default thunk itself is NOT a generator — it's a regular function
    // whose body may contain yield that suspends the *enclosing* generator.
    def_ctx.is_generator = self.is_generator;

    // Propagate MODULE context so top-level `await` is recognized as an
    // operator inside default expressions at module scope (e.g.
    // `export var { x = await foo } = {}`). We deliberately do NOT blanket-copy
    // self.is_async: for an async function/method's *parameter* defaults the
    // enclosing is_async is already handled by the existing param path, and
    // copying it here regresses async-method default params. Module top-level
    // is the only context where the default thunk itself must see await, and
    // there is_module gates it precisely.
    def_ctx.is_module = self.is_module;
    if (self.is_module) def_ctx.is_async = self.is_async;

    // Propagate class context (for super expressions)
    def_ctx.in_class_body = self.in_class_body;
    def_ctx.has_super_binding = self.has_super_binding;
    def_ctx.super_is_home_object = self.super_is_home_object;
    def_ctx.super_is_static_method = self.super_is_static_method;
    def_ctx.adopt_private_names(self);
    def_ctx.private_scope_start = self.private_scope_start;
    def_ctx.private_scope_depth = self.private_scope_depth;

    // Per ES2015 §13.3.3.7 step 3 (NamedEvaluation), if the default is an
    // anonymous function/arrow/class/generator expression, the resulting
    // function object gets the binding identifier as its name. We
    // propagate this via the inferred_name slot — `function_expr` /
    // arrow / class / generator consults `has_inferred_name` (set by
    // the var initializer path in `decl_var`) and tags the function.
    if (inferred_name.len > 0 && inferred_name.len < 128) {
        def_ctx.has_inferred_name = true;
        def_ctx.inferred_name_len = (ushort)inferred_name.len;
        for (usz i = 0; i < (usz)inferred_name.len; i++) {
            def_ctx.inferred_name_buf[i] = inferred_name[i];
        }
    }

    // Function-level lexical scope (empty — no parameters)
    def_ctx.emit_simple(Opcode.PUSH_LEX);

    // Compile expression with implicit return
    ushort expr_reg = def_ctx.assignment_expr()!;
    def_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);

    // Pop the function-level lexical scope
    def_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = def_ctx.finish()!;

    // The default expression thunk is NOT a generator function itself — it's
    // a regular zero-arg function that may contain yield expressions which
    // suspend the *enclosing* generator. Clear the is_generator flag set by
    // finish() (propagated from the enclosing context) so the VM's CALL
    // handler treats it as a normal function call, not a generator creation.
    func.flags.is_generator = false;

    // If the default expression references 'arguments', clear the thunk's
    // flag (prevent VM from creating a thunk-specific arguments object that
    // shadows the parent's) and propagate to the enclosing function so the
    // VM creates the parent's arguments object.
    if (def_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        self.uses_arguments = true;
    }

    // Default thunks need their parent's lex scope bridged into the
    // activation so TDZ sentinels for params are visible via GETVAR.
    func.flags.needs_lex_bridge = true;

    return func;
}

/// Compile a computed property key expression into a 0-arg inner function.
/// The caller must have already consumed the `[` token.
/// This function compiles the expression and `]` is consumed by the caller after.
fn CompiledFunction*? CompilerContext.compile_key_expr(&self) {
    CompilerContext key_ctx;
    key_ctx.init(self.lexer, self.heap);
    key_ctx.lexer.set_strict(true);
    key_ctx.in_class_body = self.in_class_body;
    key_ctx.has_super_binding = self.has_super_binding;
    key_ctx.super_is_home_object = self.super_is_home_object;
    key_ctx.super_is_static_method = self.super_is_static_method;
    // Propagate generator/async context so yield/await resolve correctly
    // in computed property keys (e.g. [yield] inside a generator).
    key_ctx.is_generator = self.is_generator;
    key_ctx.is_async = self.is_async;

    key_ctx.emit_simple(Opcode.PUSH_LEX);
    ushort expr_reg = key_ctx.assignment_expr()!;
    key_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    key_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = key_ctx.finish()!;
    return func;
}

/// Compile an inner function (parameters + body) into a sub-CompiledFunction.
/// If `is_named_expr` is true and `name` is non-empty, the resulting function
/// is tagged with `is_namebinding`, signalling the VM to bind `name` to the
/// function object in a fresh lexical environment at call time (per ES2015
/// §14.1.20 NamedEvaluation).
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name, bool is_named_expr = false, uint src_start = 0xFFFFFFFF, bool is_expr = false) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);

    inner_ctx.lexer.set_strict(true);

    // Propagate strict mode: inner functions inherit enclosing strict context.
    inner_ctx.is_strict = self.is_strict;

    // Propagate generator flag: if the caller is compiling a generator,
    // the inner context (which parses the body) needs to know it's in a generator.
    inner_ctx.is_generator = self.is_generator;

    // Propagate async flag: if the caller is compiling an async function,
    // the inner context (which parses the body) needs to know it's in an async function.
    // Async functions also set is_generator so they can use YIELD/LOAD_RESUME
    // for suspend/resume via the AWAIT opcode.
    inner_ctx.is_async = self.is_async;
    if (inner_ctx.is_async) inner_ctx.is_generator = true;

    // Propagate class context (for super expressions)
    inner_ctx.in_class_body = self.in_class_body;
    inner_ctx.has_super_binding = self.has_super_binding;
    inner_ctx.super_is_home_object = self.super_is_home_object;
    inner_ctx.super_is_static_method = self.super_is_static_method;
    // Propagate constructable flag: super() only valid in constructors
    inner_ctx.is_constructable = self.is_constructable;
    // Propagate private-name declarations (ES2022): a method/getter/setter
    // body compiled here must resolve `this.#x` against the enclosing class
    // body's declared names — resolve_private_name reads these fields
    // directly, so they must be copied (not just in_class_body).
    inner_ctx.adopt_private_names(self);
    inner_ctx.private_scope_start = self.private_scope_start;
    inner_ctx.private_scope_depth = self.private_scope_depth;

    // Parse parameter list
    inner_ctx.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Track seen param names for duplicate-param rejection (strict-only engine).
    char[64][MAX_PARAMS] inner_seen_names;
    ushort[MAX_PARAMS]    inner_seen_lens;
    uint inner_seen_count = 0;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] inner_destruct_binds;
    uint inner_destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] inner_destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] inner_destruct_group_regs;

    if (!inner_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (inner_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...{a, b} or ...[a, b]
                if (inner_ctx.check(TokenType.LBRACE)) {
                    inner_ctx.advance()!;
                    inner_ctx.alloc_reg();
                    inner_ctx.collect_obj_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else if (inner_ctx.check(TokenType.LBRACKET)) {
                    inner_ctx.advance()!;
                    inner_ctx.alloc_reg();
                    inner_ctx.collect_arr_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = inner_ctx.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    if (is_restricted_name(rest_param.str_value)) {
                        return COMPILE_ERROR~;
                    }
                    if (check_dup_param(rest_param.str_value, inner_seen_names[..], inner_seen_lens[..], inner_seen_count)) {
                        return COMPILE_ERROR~;
                    }
                    if (inner_seen_count < MAX_PARAMS && rest_param.str_value.len < 64) {
                        for (usz k = 0; k < rest_param.str_value.len; k++) {
                            inner_seen_names[inner_seen_count][k] = rest_param.str_value[k];
                        }
                        inner_seen_lens[inner_seen_count] = (ushort)rest_param.str_value.len;
                        inner_seen_count++;
                    }
                    ushort rest_reg = inner_ctx.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = inner_ctx.add_string_constant(rest_param.str_value);
                    inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                inner_ctx.has_rest = true;
                inner_ctx.rest_formal_count = arg_count - 1;
                inner_ctx.num_args = arg_count;
                inner_ctx.formal_count = formal_count;
                // Rest parameter must be last
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (inner_ctx.check(TokenType.LBRACE)) {
                inner_ctx.advance()!;
                // Reserve the formal parameter register slot so the incoming
                // argument stays live through all destructuring extractions
                // and isn't reused by a later parameter's register allocation.
                inner_ctx.alloc_reg();
                // The destructuring pattern itself must be consumed FIRST
                // (the closing `}` happens before the `= default`), then we
                // check for the outer default. The default check itself is
                // deferred (see emit_destruct_param_defaults) until every
                // parameter's arg slot is known, so its scratch registers
                // can't clobber a later parameter's live argument.
                inner_ctx.collect_obj_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = inner_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    inner_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!inner_ctx.match(TokenType.COMMA)) break;
                if (inner_ctx.check(TokenType.RPAREN)) break;
                continue;
            } else if (inner_ctx.check(TokenType.LBRACKET)) {
                inner_ctx.advance()!;
                // Reserve the formal parameter register slot (see LBRACE above).
                inner_ctx.alloc_reg();
                // Same shape as the LBRACE branch above.
                inner_ctx.collect_arr_param_binds(inner_destruct_binds[..], &inner_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = inner_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    inner_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!inner_ctx.match(TokenType.COMMA)) break;
                if (inner_ctx.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = inner_ctx.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            if (check_dup_param(param.str_value, inner_seen_names[..], inner_seen_lens[..], inner_seen_count)) {
                return COMPILE_ERROR~;
            }
            if (inner_seen_count < MAX_PARAMS && param.str_value.len < 64) {
                for (usz k = 0; k < param.str_value.len; k++) {
                    inner_seen_names[inner_seen_count][k] = param.str_value[k];
                }
                inner_seen_lens[inner_seen_count] = (ushort)param.str_value.len;
                inner_seen_count++;
            }
            ushort param_reg = inner_ctx.declare_var(param.str_value, VAR);
            uint param_name_idx = inner_ctx.add_string_constant(param.str_value);
            arg_count++;
            // DECLVAR creates binding in var_env.
            inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Check for default value
            if (inner_ctx.check(TokenType.ASSIGN)) {
                inner_ctx.advance()!; // consume '='

                // Pass param name for NamedEvaluation tagging.
                CompiledFunction* default_func = inner_ctx.compile_default_expr(param.str_value)!;

                // Add to inner functions table
                if (inner_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = inner_ctx.add_inner_func(default_func);
                    inner_ctx.defaults[inner_ctx.default_count].param_reg = param_reg;
                    inner_ctx.defaults[inner_ctx.default_count].param_name_idx = param_name_idx;
                    inner_ctx.defaults[inner_ctx.default_count].default_func_idx = def_idx;
                    inner_ctx.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!inner_ctx.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (inner_ctx.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!inner_ctx.has_rest) {
        inner_ctx.num_args = arg_count;
    }
    inner_ctx.formal_count = formal_count;

    inner_ctx.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables (skip synthetics).
    for (uint i = 0; i < inner_destruct_count; i++) {
        if (inner_destruct_binds[i].is_synthetic) {
            inner_destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = inner_destruct_binds[i].name_idx;
        char[] bind_name = inner_destruct_binds[i].name_buf[:inner_destruct_binds[i].name_len];
        ushort dreg = inner_ctx.declare_var(bind_name, VAR);
        inner_destruct_binding_regs[i] = dreg;
        inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }

    // Push a function-level lexical scope for let/const at function top level.
    // Skip when there are no default parameters.
    bool inner_has_func_lex = inner_ctx.default_count > 0;
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            inner_ctx.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            inner_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < inner_ctx.default_count; di++) {
        ushort pr = inner_ctx.defaults[di].param_reg;
        uint name_idx = inner_ctx.defaults[di].param_name_idx;
        uint func_idx = inner_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        inner_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = inner_ctx.code_count;
        inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        inner_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = inner_ctx.alloc_reg();
        if (inner_ctx.next_reg <= call_base + 1) {
            inner_ctx.next_reg = call_base + 2;
        }
        ushort this_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Assign result to parameter register and sync to environment.
        // GETVAR reloads from env to pr because PUTVAR clears its source register.
        inner_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        inner_ctx.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
        inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to var_env — always executed (creates binding if deferred).
        inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        inner_ctx.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (inner_has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < inner_ctx.default_count; di++) {
                if (inner_ctx.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                inner_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit deferred outer-default checks for destructured parameters, now
    // that every parameter's arg slot is finalised (see
    // parse_destruct_param_default / emit_destruct_param_defaults).
    inner_ctx.emit_destruct_param_defaults();

    // Emit destructuring code for inner function parameters.
    inner_ctx.emit_destruct_bindings(inner_destruct_binds[..], inner_destruct_count,
                                     inner_destruct_group_regs[..], inner_destruct_binding_regs[..]);

    // Generator functions: emit GEN_START after all parameter initialization
    // so the VM can run eagerly up to this point on the initial call.
    if (inner_ctx.is_generator && !inner_ctx.is_async) {
        inner_ctx.emit_simple(Opcode.GEN_START);
    }

    // Collect names captured by nested callables (plan 045).
    inner_ctx.pre_scan_captures();

    // Per ES2015 §9.2.10 step 27: when hasParameterExpressions is true,
    // a separate VariableEnvironment is needed for the function body so
    // that closures created by default parameter expressions do not have
    // visibility of var declarations in the function body.
    // PUSH_VAR creates a new var_env (and lex_env) child of the current
    // var_env, isolating body vars from the parameter scope.
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.PUSH_VAR);
    }

    // Hoist var and function declarations to the top of the inner function scope.
    inner_ctx.hoist_decls(false)!;

    // Params and hoisted slots are now allocated — pin them for the body.
    inner_ctx.reserved_regs = inner_ctx.next_reg;

    // Compile function body. When this function is being parsed as an
    // expression (function expression, method value, etc.) the closing `}`
    // is not a statement boundary — the whole function is an operand, so a
    // following `/` must be read as division, not a RegularExpressionLiteral
    // (see Lexer.note_block_close doc).
    inner_ctx.block(true, is_expr)!;
    // Capture body-end position so Function.prototype.toString returns the
    // exact source span (without trailing whitespace / line-terminators).
    uint inner_body_end_pos = inner_ctx.lexer.pos;

    // Pop the body's variable scope (undo PUSH_VAR)
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.POP_VAR);
    }

    // Pop the function-level lexical scope (undo PUSH_LEX for parameter TDZ)
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Add implicit return undefined
    bool has_return = false;
    if (inner_ctx.code_count > 0) {
        Opcode last_op = inner_ctx.code[inner_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        inner_ctx.emit_simple((inner_ctx.is_generator && !inner_ctx.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }

    CompiledFunction* func = inner_ctx.finish()!;

    func.flags.is_strict = inner_ctx.is_strict;

    // Set function name. The name parameter is a slice into the caller's
    // inferred_name_buf (or a lexer token buffer), which gets reused for
    // subsequent function compilations. Copy the bytes into a heap allocation
    // that outlives the compile context, so each CompiledFunction holds its
    // own stable copy of its name.
    if (name.len > 0) {
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)name.len + 1)) ?? null;
        if (name_heap != null) {
            for (usz i = 0; i < (usz)name.len; i++) name_heap[i] = name[i];
            name_heap[name.len] = 0;
            func.name_ptr = name_heap;
            func.name_len = (uint)name.len;
            // Named function expression: tag so the VM creates a lexical
            // environment binding for `name` at call time (ES2015 §14.1.20).
            if (is_named_expr) {
                func.flags.is_namebinding = true;
            }
        }
    }

    // Retain a heap-owned copy of the function's source text so that
    // Function.prototype.toString can return the original source verbatim
    // (ES2019 §19.2.3.5). The caller passes the byte offset of the function's
    // opening token (`function` keyword, computed property `[`, arrow head,
    // etc.); `inner_body_end_pos` captures the position right after the
    // body's closing `}`, so the slice is exactly the function declaration.
    //
    // For `async function ...` the consumed `async` keyword is *before* the
    // byte offset we captured (we captured `function`), so we prepend the
    // literal "async " string to the retained source to match ES2019's source
    // text representation.
    if (src_start != 0xFFFFFFFF && src_start < (uint)inner_ctx.lexer.source.len) {
        uint src_end = inner_body_end_pos;
        if (src_end > (uint)inner_ctx.lexer.source.len) src_end = (uint)inner_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        // Only synthesize the "async " prefix when the captured span does not
        // already include it. Method shorthand (`async m(){}`) captures from the
        // `async` token, whereas `async function ...` captures from `function`
        // and needs the prefix prepended.
        bool span_has_async = slen >= 6
            && inner_ctx.lexer.source[src_start] == 'a'
            && inner_ctx.lexer.source[src_start + 1] == 's'
            && inner_ctx.lexer.source[src_start + 2] == 'y'
            && inner_ctx.lexer.source[src_start + 3] == 'n'
            && inner_ctx.lexer.source[src_start + 4] == 'c'
            && inner_ctx.lexer.source[src_start + 5] == ' ';
        bool needs_async_prefix = inner_ctx.is_async && !span_has_async;
        usz alloc_len = (usz)slen + (needs_async_prefix ? (usz)6 : (usz)0);
        if (slen > 0) {
            char* src_heap = (char*)alloc::malloc_try(mem, (sz)((usz)alloc_len + 1)) ?? null;
            if (src_heap != null) {
                usz off = 0;
                if (needs_async_prefix) {
                    src_heap[off++] = 'a';
                    src_heap[off++] = 's';
                    src_heap[off++] = 'y';
                    src_heap[off++] = 'n';
                    src_heap[off++] = 'c';
                    src_heap[off++] = ' ';
                }
                for (usz i = 0; i < (usz)slen; i++) src_heap[off + i] = inner_ctx.lexer.source[src_start + i];
                src_heap[off + (usz)slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = (uint)alloc_len;
            }
        }
    }

    return func;
}

/// Parse a function expression: function name?(...) { ... }
fn ushort? CompilerContext.function_expr(&self, bool is_async_expr = false) {
    self.expect(TokenType.FUNCTION)!;
    // Capture the byte offset of `function` — used by Function.prototype.toString
    // for ES2019 §19.2.3.5 source-text retention.
    uint fexpr_src_start = self.lexer.token_start;

    // Save and reset generator state
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Save the enclosing async flag — it must survive this expression (a
    // module body's or async function's flag is read by finish()). The
    // expression's own async-ness comes from the is_async_expr parameter
    // (set by the `async function` expression caller), never from the
    // enclosing flag.
    bool saved_is_async = self.is_async;
    self.is_async = false;

    // Function expressions are constructable per ES2015 §14.1.2 — they can be
    // invoked with `new` unless they're arrow functions (handled in arrow
    // parsers) or method shorthand (constructor sets is_constructable=false
    // explicitly). Save/restore so nested functions inherit constructability.
    bool saved_is_constructable = self.is_constructable;
    self.is_constructable = true;

    // Check for generator star: function* name?() {}
    // Generator functions are never constructable (ES2015 §14.4) — `new` on
    // one must throw TypeError, so is_constructable must flip to false here.
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
        self.is_constructable = false;
    }

    // Async function expressions are not constructors (ES2017 §14.7.5).
    if (is_async_expr) {
        self.is_constructable = false;
    }

    // Optional function name. If the user didn't write one and we have an
    // inferred name from an enclosing `var f = ...` / `o = { m: ... }` /
    // object literal method shorthand, use the inferred name per ES2015
    // §14.1.20 SetFunctionName. Note: the inferred name does NOT create
    // a name binding (i.e. `f` is NOT visible inside the body), only the
    // display name on the function object.
    //
    // Always clear has_inferred_name after consumption — even when the user
    // provided an explicit name (`function bar() {}`), so a following
    // `var b = function() {}` doesn't inherit a stale name from `var a = function bar() {}`.
    char[] name;
    bool has_name = false;
    bool name_is_explicit = false;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
        has_name = true;
        name_is_explicit = true;
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    } else if (self.has_inferred_name) {
        name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        has_name = true;
        name_is_explicit = false;
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // Compile the function body into a sub-context with the expression's own
    // async flag, then restore the enclosing one.
    self.is_async = is_async_expr;
    // Use the byte offset of `function` captured right after expect() above.
    CompiledFunction* inner = self.compile_inner_function(name, name_is_explicit, fexpr_src_start, true)!;
    self.is_async = saved_is_async;

    // Restore generator flag
    self.is_generator = saved_is_generator;
    // Restore constructable flag
    self.is_constructable = saved_is_constructable;

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));

    return result;
}

/// Parse a function expression body (parameters + block) without the `function` keyword.
/// Used for method shorthand in object literals.
fn ushort? CompilerContext.function_expr_body(&self, uint src_start = 0xFFFFFFFF) {
    // ES2015 §14.3: object literal method shorthand `o = { m() {} }` —
    // the function's name is inferred from the property key. Caller
    // (object_literal / class_body parser) sets has_inferred_name before
    // calling. After consumption clear it so nested functions don't inherit.
    char[] name;
    if (self.has_inferred_name) {
        name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }
    // Capture byte offset of the opening of the method body — the caller
    // optionally supplies `src_start` if it knows the start of the full
    // declaration (e.g. `get f` for an object-literal getter, `[expr]` for a
    // computed key, or the leading `*` for a generator method). When the
    // caller doesn't supply one, fall back to the position of the `(` that
    // opens the parameter list (which is what we have just consumed).
    uint mexpr_src_start = src_start != 0xFFFFFFFF ? src_start : self.lexer.token_start;
    CompiledFunction* inner = self.compile_inner_function(name, false, mexpr_src_start, true)!;

    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse an arrow function by re-parsing the parameter list from source.
/// The lexer is positioned right after '(' when called. This function
/// re-parses params (including defaults, rest params, etc.) and compiles the body.
/// Called from primary_expr after the arrow detection scan confirms '=>' follows.
fn ushort? CompilerContext.parse_arrow_function_reparse(&self, uint src_start = 0xFFFFFFFF) {
    // Apply inferred name (from enclosing `var f = ...`) per ES2015 §14.1.20.
    char[] arrow_name;
    if (self.has_inferred_name) {
        arrow_name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }

    // If primary_expr set pending_async_arrow_src before consuming `async` and
    // re-entering, override the caller's src_start so the retained source text
    // begins at `async` rather than `(` (ES2019 §19.2.3.5).
    // The marker doubles as the async signal: it is set exactly when
    // primary_expr consumed `async` in front of this arrow.
    bool arrow_is_async = self.pending_async_arrow_src != 0xFFFFFFFF;
    uint effective_src_start = arrow_is_async
        ? self.pending_async_arrow_src
        : src_start;
    self.pending_async_arrow_src = 0xFFFFFFFF;

    // Create inner CompiledFunction for the arrow
    CompiledFunction* inner = self.compile_arrow_inner_reparse(effective_src_start, arrow_is_async)!;

    if (arrow_name.len > 0) {
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)arrow_name.len + 1)) ?? null;
        if (name_heap != null) {
            for (usz i = 0; i < (usz)arrow_name.len; i++) name_heap[i] = arrow_name[i];
            name_heap[arrow_name.len] = 0;
            inner.name_ptr = name_heap;
            inner.name_len = (uint)arrow_name.len;
        }
    }

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function by re-parsing params from source.
/// The lexer is positioned right after '(' when called. This function
/// parses '(params) => body', handling defaults, rest params, etc.
fn CompiledFunction*? CompilerContext.compile_arrow_inner_reparse(&self, uint src_start = 0xFFFFFFFF, bool is_async_arrow = false) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // `async (params) => ...` bodies must run resumably like async functions
    // (AWAIT is only valid in an is_async context). The flag comes from the
    // explicit async marker on this arrow, never from the enclosing body —
    // a plain arrow inside an async function or TLA module is synchronous.
    arrow_ctx.is_async = is_async_arrow;
    if (arrow_ctx.is_async) arrow_ctx.is_generator = true;

    // Propagate class context (for super expressions).
    // Arrow functions inherit super binding and constructability from the enclosing
    // function — they lexically capture `this` and HomeObject from the outer scope.
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;
    arrow_ctx.super_is_home_object = self.super_is_home_object;
    arrow_ctx.super_is_static_method = self.super_is_static_method;
    arrow_ctx.is_constructable = self.is_constructable;
    arrow_ctx.adopt_private_names(self);
    arrow_ctx.private_scope_start = self.private_scope_start;
    arrow_ctx.private_scope_depth = self.private_scope_depth;

    // Parse parameter list from source (including defaults and rest)
    // Note: lexer is already past '(' when called from parse_arrow_function_reparse
    ushort arg_count = 0;
    ushort formal_count = 0;  // params that count toward function.length

    // Track all param name indices for TDZ (needed when defaults exist).
    uint[MAX_PARAMS] param_name_indices;
    ushort first_default_idx = 0xFFFF;

    // Destructured parameter binding tracking
    DestructBind[MAX_DESTRUCT_BINDS] arrow_destruct_binds;
    uint arrow_destruct_count = 0;
    ushort[MAX_DESTRUCT_BINDS] arrow_destruct_binding_regs;
    ushort[MAX_DESTRUCT_BINDS] arrow_destruct_group_regs;

    if (!arrow_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (arrow_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param;

                // Check for destructured rest: ...{a, b} or ...[a, b]
                if (arrow_ctx.check(TokenType.LBRACE)) {
                    arrow_ctx.advance()!;
                    arrow_ctx.alloc_reg();
                    arrow_ctx.collect_obj_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else if (arrow_ctx.check(TokenType.LBRACKET)) {
                    arrow_ctx.advance()!;
                    arrow_ctx.alloc_reg();
                    arrow_ctx.collect_arr_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                    rest_param.str_value = {};
                } else {
                    rest_param = arrow_ctx.expect(TokenType.IDENTIFIER)!;
                }

                if (rest_param.str_value.len > 0) {
                    ushort rest_reg = arrow_ctx.declare_var(rest_param.str_value, VAR);
                    uint rest_name_idx = arrow_ctx.add_string_constant(rest_param.str_value);
                    arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                }
                arg_count++;
                arrow_ctx.has_rest = true;
                arrow_ctx.rest_formal_count = arg_count - 1;
                arrow_ctx.num_args = arg_count;
                arrow_ctx.formal_count = formal_count;
                break;
            }

            // Check for destructuring pattern as parameter: {a, b} or [a, b]
            if (arrow_ctx.check(TokenType.LBRACE)) {
                arrow_ctx.advance()!;
                arrow_ctx.alloc_reg();
                arrow_ctx.collect_obj_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = arrow_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    arrow_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!arrow_ctx.match(TokenType.COMMA)) break;
                if (arrow_ctx.check(TokenType.RPAREN)) break;
                continue;
            } else if (arrow_ctx.check(TokenType.LBRACKET)) {
                arrow_ctx.advance()!;
                arrow_ctx.alloc_reg();
                arrow_ctx.collect_arr_param_binds(arrow_destruct_binds[..], &arrow_destruct_count, (ushort)arg_count, 0xFFFF)!;
                bool has_default = arrow_ctx.parse_destruct_param_default((ushort)arg_count)!;
                if (!has_default) {
                    arrow_ctx.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_count, 0, 0);
                }
                if (has_default && first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count;
                }
                arg_count++;
                if (first_default_idx == 0xFFFF) { formal_count++; }
                if (!arrow_ctx.match(TokenType.COMMA)) break;
                if (arrow_ctx.check(TokenType.RPAREN)) break;
                continue;
            }

            Token param = arrow_ctx.expect(TokenType.IDENTIFIER)!;
            ushort param_reg = arrow_ctx.declare_var(param.str_value, VAR);
            uint param_name_idx = arrow_ctx.add_string_constant(param.str_value);
            arg_count++;
            // DECLVAR creates binding in var_env.
            arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);

            // Check for default value
            if (arrow_ctx.check(TokenType.ASSIGN)) {
                arrow_ctx.advance()!; // consume '='

                // Pass param name for NamedEvaluation tagging.
                CompiledFunction* default_func = arrow_ctx.compile_default_expr(param.str_value)!;

                // Add to inner functions table
                if (arrow_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = arrow_ctx.add_inner_func(default_func);
                    arrow_ctx.defaults[arrow_ctx.default_count].param_reg = param_reg;
                    arrow_ctx.defaults[arrow_ctx.default_count].param_name_idx = param_name_idx;
                    arrow_ctx.defaults[arrow_ctx.default_count].default_func_idx = def_idx;
                    arrow_ctx.default_count++;
                }

                // Track first default index (0-based arg index)
                if (first_default_idx == 0xFFFF) {
                    first_default_idx = arg_count - 1;
                }
            }
            // Params after the first default don't count toward .length (ES6 §14.1.6).
            if (first_default_idx == 0xFFFF) { formal_count++; }

            // Store name index for TDZ (all params when defaults exist).
            param_name_indices[arg_count - 1] = param_name_idx;

            if (!arrow_ctx.match(TokenType.COMMA)) {
                break;
            }
            // Trailing comma: ',)' is valid per ES2017
            if (arrow_ctx.check(TokenType.RPAREN)) {
                break;
            }
        }
    }

    if (!arrow_ctx.has_rest) {
        arrow_ctx.num_args = arg_count;
    }
    arrow_ctx.formal_count = formal_count;

    arrow_ctx.expect(TokenType.RPAREN)!;

    // Declare destructured bindings as variables (skip synthetics).
    for (uint i = 0; i < arrow_destruct_count; i++) {
        if (arrow_destruct_binds[i].is_synthetic) {
            arrow_destruct_binding_regs[i] = 0xFFFF;
            continue;
        }
        uint ni = arrow_destruct_binds[i].name_idx;
        char[] bind_name = arrow_destruct_binds[i].name_buf[:arrow_destruct_binds[i].name_len];
        ushort dreg = arrow_ctx.declare_var(bind_name, VAR);
        arrow_destruct_binding_regs[i] = dreg;
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)dreg, ni);
    }

    // Consume the => token
    arrow_ctx.expect(TokenType.ARROW)!;

    // Push a function-level lexical scope
    bool has_func_lex = arrow_ctx.default_count > 0;
    if (has_func_lex) {
        arrow_ctx.emit_simple(Opcode.PUSH_LEX);

        // TDZ: initialize ALL params with sentinels in the parameter scope.
        // When defaults exist, every param is in TDZ until its default check
        // completes (for default params) or until it becomes visible (non-default).
        for (ushort ai = 0; ai < arg_count; ai++) {
            uint ni = param_name_indices[ai];
            arrow_ctx.emit_a_bc(Opcode.INITTZ, 0, ni);
        }

        // Emit PUTLEX for pre-default params only.
        // Pre-default params are not in TDZ — they're already initialized by arguments.
        ushort ai = 0;
        while (ai < first_default_idx) {
            uint ni = param_name_indices[ai];
            arrow_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            ai++;
        }

        // After all default checks complete, emit PUTLEX for non-default params
        // that appear after the first default (they were in TDZ but should now be visible).
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < arrow_ctx.default_count; di++) {
        ushort pr = arrow_ctx.defaults[di].param_reg;
        uint name_idx = arrow_ctx.defaults[di].param_name_idx;
        uint func_idx = arrow_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        arrow_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = arrow_ctx.code_count;
        arrow_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        arrow_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = arrow_ctx.alloc_reg();
        arrow_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = arrow_ctx.alloc_reg();
        if (arrow_ctx.next_reg <= call_base + 1) {
            arrow_ctx.next_reg = call_base + 2;
        }
        arrow_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        arrow_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        arrow_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Copy result directly to the parameter register.
        arrow_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);

        arrow_ctx.free_regs_to(call_base);

        // Patch the skip jump to land AFTER free_regs_to but BEFORE PUTVAR.
        int skip_off = (int)arrow_ctx.code_count - (int)skip_addr - 1;
        arrow_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        // Write to var_env — always executed (creates binding if deferred).
        arrow_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        arrow_ctx.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);
    }

    // Emit PUTLEX for non-default params that appear after the first default.
    // These were in TDZ but should now be visible once all defaults are evaluated.
    if (has_func_lex && first_default_idx != 0xFFFF) {
        ushort ai = first_default_idx;
        while (ai < arg_count) {
            uint ni = param_name_indices[ai];
            // Check if this param has a default (was already handled above).
            bool is_default_param = false;
            for (ushort di = 0; di < arrow_ctx.default_count; di++) {
                if (arrow_ctx.defaults[di].param_name_idx == ni) {
                    is_default_param = true;
                    break;
                }
            }
            if (!is_default_param) {
                arrow_ctx.emit_a_bc(Opcode.PUTLEX, 0, ni);
            }
            ai++;
        }
    }

    // Emit deferred outer-default checks for destructured parameters, now
    // that every parameter's arg slot is finalised (see
    // parse_destruct_param_default / emit_destruct_param_defaults).
    arrow_ctx.emit_destruct_param_defaults();

    // Emit destructuring code for arrow function parameters.
    arrow_ctx.emit_destruct_bindings(arrow_destruct_binds[..], arrow_destruct_count,
                                     arrow_destruct_group_regs[..], arrow_destruct_binding_regs[..]);

    // Determine if body is block or expression. Capture `body_end_pos` right
    // after the last body token (before any trailing whitespace or comment) so
    // Function.prototype.toString returns the exact source span.
    uint body_end_pos;
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Collect names captured by nested callables (plan 045).
        arrow_ctx.pre_scan_captures();
        // Params are allocated — pin them for the body.
        arrow_ctx.reserved_regs = arrow_ctx.next_reg;
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        body_end_pos = arrow_ctx.lexer.pos;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value.
        // Pre-scan in expression mode: nested arrows/functions inside the
        // expression can capture this arrow's params (plan 045).
        arrow_ctx.pre_scan_captures(true);
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
        body_end_pos = arrow_ctx.lexer.pos;
    }

    // Pop the function-level lexical scope
    if (has_func_lex) {
        arrow_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Set rest and formal counts before finish()
    arrow_ctx.num_args = arg_count;
    if (arrow_ctx.has_rest) {
        arrow_ctx.rest_formal_count = arg_count - 1;
    }

    CompiledFunction* func = arrow_ctx.finish()!;

    // `arguments` in an arrow body refers lexically to the enclosing ordinary
    // function's arguments object. Clear the arrow's own flag so the VM does
    // not create a fresh (empty) arguments object that shadows the parent's,
    // and propagate the requirement to the enclosing function so it creates
    // and env-declares the object the arrow's GETVAR "arguments" resolves to.
    if (arrow_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        self.uses_arguments = true;
    }

    // Retain source text for Function.prototype.toString (ES2019 §19.2.3.5).
    // See compile_inner_function for rationale. We use `body_end_pos` (captured
    // right after the last body token) as src_end so trailing whitespace and
    // comments after the body don't leak into the slice.
    if (src_start != 0xFFFFFFFF && src_start < (uint)arrow_ctx.lexer.source.len) {
        uint src_end = body_end_pos;
        // Trim trailing whitespace, line-terminators, and comments. The body
        // parser may have peeked-ahead, landing lexer.pos inside trailing
        // whitespace + comments. Walk back over trailing cruft.
        while (src_end > src_start) {
            char c = arrow_ctx.lexer.source[src_end - 1];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') {
                src_end--;
                continue;
            }
            // If we hit end-of-block-comment (`/` followed by `*`), scan
            // backward to find the matching `/*` and remove the whole
            // comment.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '*') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '*') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    i--;
                }
                if (!found) break;
                continue;
            }
            // Line comment: scan back to leading `//`.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '/') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '/') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    if (arrow_ctx.lexer.source[i - 1] == '\n') break;
                    i--;
                }
                if (!found) break;
                continue;
            }
            break;
        }
        if (src_end > (uint)arrow_ctx.lexer.source.len) src_end = (uint)arrow_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        if (slen > 0) {
            char* src_heap = (char*)alloc::malloc_try(mem, (sz)((usz)slen + 1)) ?? null;
            if (src_heap != null) {
                for (usz i = 0; i < (usz)slen; i++) src_heap[i] = arrow_ctx.lexer.source[src_start + i];
                src_heap[slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = slen;
            }
        }
    }

    return func;
}

/// Parse an arrow function: `(params) => expr` or `(params) => { body }`
/// or `param => expr`.  The caller has already consumed the leading `(`
/// or the single identifier.
///
/// `params`: pre-parsed parameter name slices (pointer to first element).
/// `param_count`: number of parameters.
fn ushort? CompilerContext.parse_arrow_function(&self, char[]* params, ushort param_count, bool has_rest, uint src_start = 0xFFFFFFFF) {
    // Consume the ARROW token
    self.expect(TokenType.ARROW)!;

    // Create inner CompiledFunction for the arrow — apply inferred name
    // (from enclosing `var f = ...`) per ES2015 §14.1.20 SetFunctionName.
    char[] arrow_name;
    if (self.has_inferred_name) {
        arrow_name = self.inferred_name_buf[:(uint)self.inferred_name_len];
        self.has_inferred_name = false;
        self.inferred_name_len = 0;
    }
    // If primary_expr recorded the `async` keyword's position before
    // consuming it and re-entering (async arrow form `async param => body`),
    // use that offset so toString() starts at `async` (ES2019 §19.2.3.5).
    // The marker doubles as the async signal: it is set exactly when
    // primary_expr consumed `async` in front of this arrow.
    bool arrow_is_async = self.pending_async_arrow_src != 0xFFFFFFFF;
    uint effective_src_start = arrow_is_async
        ? self.pending_async_arrow_src
        : src_start;
    self.pending_async_arrow_src = 0xFFFFFFFF;
    CompiledFunction* inner = self.compile_arrow_inner(params, param_count, has_rest, effective_src_start, arrow_is_async)!;

    // Set the function's display name from the inferred source. This is a
    // non-binding name (no lexical scope entry) — only the name property.
    if (arrow_name.len > 0) {
        char* name_heap = (char*)alloc::malloc_try(mem, (sz)((usz)arrow_name.len + 1)) ?? null;
        if (name_heap != null) {
            for (usz i = 0; i < (usz)arrow_name.len; i++) name_heap[i] = arrow_name[i];
            name_heap[arrow_name.len] = 0;
            inner.name_ptr = name_heap;
            inner.name_len = (uint)arrow_name.len;
        }
    }

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function given its parameter names.
/// Arrow functions have `is_arrow = true`, lexical `this`, and no `.prototype`.
fn CompiledFunction*? CompilerContext.compile_arrow_inner(&self, char[]* params, ushort param_count, bool has_rest, uint src_start = 0xFFFFFFFF, bool is_async_arrow = false) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // `async (params) => ...` bodies must run resumably like async functions
    // (AWAIT is only valid in an is_async context). The flag comes from the
    // explicit async marker on this arrow, never from the enclosing body —
    // a plain arrow inside an async function or TLA module is synchronous.
    arrow_ctx.is_async = is_async_arrow;
    if (arrow_ctx.is_async) arrow_ctx.is_generator = true;

    // Propagate class context (for super expressions).
    // Arrow functions inherit super binding and constructability from the enclosing
    // function — they lexically capture `this` and HomeObject from the outer scope.
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;
    arrow_ctx.super_is_home_object = self.super_is_home_object;
    arrow_ctx.super_is_static_method = self.super_is_static_method;
    arrow_ctx.is_constructable = self.is_constructable;
    arrow_ctx.adopt_private_names(self);
    arrow_ctx.private_scope_start = self.private_scope_start;
    arrow_ctx.private_scope_depth = self.private_scope_depth;

    // Register parameters
    ushort formal_count = param_count;
    if (has_rest && param_count > 0) {
        formal_count = param_count - 1;
    }
    // Per ES2015 §9.2.10 step 32: strict-mode arrow functions create a fresh
    // declarative environment for parameters and body vars, isolating them
    // from the captured lexical environment. PUSH_VAR creates a fresh env with
    // the captured lex as the outer, then DECLVAR writes the parameter to it
    // instead of polluting the parent's bindings.
    arrow_ctx.emit_simple(Opcode.PUSH_VAR);
    for (ushort i = 0; i < param_count; i++) {
        char[] name = params[i];
        if (is_restricted_name(name)) {
            return COMPILE_ERROR~;
        }
        for (ushort j = 0; j < i; j++) {
            char[] prev = params[j];
            if (prev.len == name.len) {
                bool match = true;
                for (usz k = 0; k < name.len; k++) {
                    if (prev[k] != name[k]) { match = false; break; }
                }
                if (match) return COMPILE_ERROR~;
            }
        }
        ushort param_reg = arrow_ctx.declare_var(name, VAR);
        uint param_name_idx = arrow_ctx.add_string_constant(name);
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
    }

    // Push a function-level lexical scope
    arrow_ctx.emit_simple(Opcode.PUSH_LEX);

    // Determine if body is block or expression. Capture `body_end_pos` right
    // after the last body token (before any trailing whitespace or comment) so
    // Function.prototype.toString returns the exact source span.
    uint body_end_pos;
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Collect names captured by nested callables (plan 045).
        arrow_ctx.pre_scan_captures();
        // Params are allocated — pin them for the body.
        arrow_ctx.reserved_regs = arrow_ctx.next_reg;
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        body_end_pos = arrow_ctx.lexer.pos;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value.
        // Pre-scan in expression mode: nested arrows/functions inside the
        // expression can capture this arrow's params (plan 045).
        arrow_ctx.pre_scan_captures(true);
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
        body_end_pos = arrow_ctx.lexer.pos;
    }

    // Pop the function-level lexical scope
    arrow_ctx.emit_simple(Opcode.POP_LEX);
    // Pop the function-level variable scope (PUSH_VAR for parameter isolation)
    arrow_ctx.emit_simple(Opcode.POP_VAR);

    // Set rest and formal counts before finish()
    arrow_ctx.has_rest = has_rest;
    arrow_ctx.rest_formal_count = formal_count;
    arrow_ctx.num_args = param_count;

    CompiledFunction* func = arrow_ctx.finish()!;

    // `arguments` in an arrow body refers lexically to the enclosing ordinary
    // function's arguments object. Clear the arrow's own flag so the VM does
    // not create a fresh (empty) arguments object that shadows the parent's,
    // and propagate the requirement to the enclosing function so it creates
    // and env-declares the object the arrow's GETVAR "arguments" resolves to.
    if (arrow_ctx.uses_arguments) {
        func.flags.uses_arguments = false;
        self.uses_arguments = true;
    }

    // Retain source text for Function.prototype.toString (ES2019 §19.2.3.5).
    // See compile_inner_function for rationale. We use `body_end_pos` (captured
    // right after the last body token) as src_end so trailing whitespace and
    // comments after the body don't leak into the slice.
    if (src_start != 0xFFFFFFFF && src_start < (uint)arrow_ctx.lexer.source.len) {
        uint src_end = body_end_pos;
        // Trim trailing whitespace, line-terminators, and comments. The body
        // parser may have peeked-ahead, landing lexer.pos inside trailing
        // whitespace + comments. Walk back over trailing cruft.
        while (src_end > src_start) {
            char c = arrow_ctx.lexer.source[src_end - 1];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == ';') {
                src_end--;
                continue;
            }
            // If we hit end-of-block-comment (`/` followed by `*`), scan
            // backward to find the matching `/*` and remove the whole
            // comment.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '*') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '*') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    i--;
                }
                if (!found) break;
                continue;
            }
            // Line comment: scan back to leading `//`.
            if (c == '/' && src_end >= src_start + 2
                    && arrow_ctx.lexer.source[src_end - 2] == '/') {
                uint i = src_end - 2;
                bool found = false;
                while (i > src_start) {
                    if (arrow_ctx.lexer.source[i - 1] == '/' && i >= src_start + 1
                            && arrow_ctx.lexer.source[i] == '/') {
                        src_end = i - 1;
                        found = true;
                        break;
                    }
                    if (arrow_ctx.lexer.source[i - 1] == '\n') break;
                    i--;
                }
                if (!found) break;
                continue;
            }
            break;
        }
        if (src_end > (uint)arrow_ctx.lexer.source.len) src_end = (uint)arrow_ctx.lexer.source.len;
        uint slen = src_end - src_start;
        if (slen > 0) {
            char* src_heap = (char*)alloc::malloc_try(mem, (sz)((usz)slen + 1)) ?? null;
            if (src_heap != null) {
                for (usz i = 0; i < (usz)slen; i++) src_heap[i] = arrow_ctx.lexer.source[src_start + i];
                src_heap[slen] = 0;
                func.src_ptr = src_heap;
                func.src_len = slen;
            }
        }
    }

    return func;
}
