module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::re_bindings;
import std::io;
import std::collections::list;

// Whether a template substitution's ToString may move from its source
// position into the STRJOIN that builds the template string.
enum PartKind : uint {
    // The value could be an object or symbol, so its conversion can run user
    // code or throw; it must happen at the substitution's source position.
    PART_UNKNOWN,
    // Provably a primitive whose ToString is pure and cannot throw (string,
    // number, bigint, boolean, null, undefined): safe to convert in the join.
    PART_DEFER,
}

// Bookkeeping for a resolved-by-name identifier that turned out to be
// `arguments`. emit_ident_read calls this for every bare-identifier read;
// TYPEOFIDENT is emitted directly and calls it itself. Two effects:
//
//  - ES2022 §15.7.1 forbids `arguments` anywhere in a class field
//    initializer, including under `typeof`.
//  - Inside a non-arrow function body the reference makes the function need
//    an arguments object, which the VM only builds when `uses_arguments` is
//    set at call entry. Missing this is silent: the name simply doesn't
//    resolve, so `typeof arguments` reads back `"undefined"`.
// The same rule for a name held as a constant-pool index, which is the form
// emit_ident_read has.
fn void? CompilerContext.note_arguments_reference_by_index(&self, uint name_idx) {
    if (name_idx >= self.const_count) return;
    TVal kv = self.constants[name_idx];
    if (!kv.is_string()) return;
    HString* hs = (HString*)kv.get_heapptr();
    if (hs == null) return;
    return self.note_arguments_reference(hs.get_data());
}

fn void? CompilerContext.note_arguments_reference(&self, char[] name) {
    if (!str_eq(name, "arguments")) return;
    if (self.forbid_arguments) {
        return self.fail("'arguments' is not allowed in class field initializer")~;
    }
    if (!self.is_global) self.uses_arguments = true;
}

// Resolve a bare or parenthesized identifier under TYPEOF to a register and
// emit register-based TYPEOF, which reads the live value rather than the
// env-walking TYPEOFIDENT. A non-captured local resolves from the scope
// stack; a REGISTER-RESIDENT module var resolves to its home register
// (its env binding is never written, so TYPEOFIDENT would report a stale
// "undefined"). Returns the TYPEOF result register, or
// SCOPE_ERROR when the name is neither, so the caller falls back to
// TYPEOFIDENT (which handles the unresolvable-reference case).
fn ushort? CompilerContext.try_emit_typeof_register(&self, char[] id_name) {
    if (!self.is_global) {
        if (try local_reg = self.resolve_var(id_name)) {
            ushort res = self.alloc_reg();
            self.emit_abc(Opcode.TYPEOF, (uint)res, (uint)local_reg, 0);
            return res;
        }
    } else if (self.is_slot_global_name(id_name)) {
        if (try ushort sreg = self.resolve_slot_global(id_name)) {
            ushort res = self.alloc_reg();
            self.emit_abc(Opcode.TYPEOF, (uint)res, (uint)sreg, 0);
            return res;
        }
    }
    return SCOPE_ERROR~;
}

struct TemplatePart {
    uint str_idx;   // cooked string constant
    uint raw_idx;   // raw string constant
    bool invalid;   // an invalid escape leaves the cooked string undefined
}

fn TemplatePart CompilerContext.template_part(&self, Token tok, bool invalid) {
    return { self.add_string_constant(tok.str_value), self.add_string_constant(tok.raw_value), invalid };
}

fn ushort CompilerContext.emit_template_call(&self, ushort callee_reg, ushort obj_reg,
    TemplatePart[] parts, ushort[] expr_regs) {
    // === Site cache: constants[cache_idx] holds this call site's frozen
    // template object across every evaluation, shared by all closures
    // instantiated from the enclosing CompiledFunction (ES2015 §12.2.9.3
    // GetTemplateObject, the cache is per Parse Node, not per closure).
    // The slot starts as `undefined`; the first evaluation builds and
    // freezes the array, then stores it back with SETCONST.
    TVal undef_tv;
    undef_tv.set_undefined();
    uint cache_idx = self.add_constant(undef_tv);

    ushort tmpl_arr_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.LDCONST, (uint)tmpl_arr_reg, cache_idx);
    ushort cache_test_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDUNDEF, (uint)cache_test_reg, 0, 0);
    self.emit_abc(Opcode.SEQ, (uint)cache_test_reg, (uint)tmpl_arr_reg, (uint)cache_test_reg);
    uint cached_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cache_test_reg);
    self.free_reg(cache_test_reg);

    // === Build the template object array (cache miss) ===
    self.emit_abc(Opcode.NEWARR, (uint)tmpl_arr_reg, 0, 0);

    // Fill with string parts (cooked values; undefined for invalid escapes)
    foreach (i, part : parts) {
        ushort elem_reg = self.alloc_reg();
        if (part.invalid) {
            self.emit_abc(Opcode.LDUNDEF, (uint)elem_reg, 0, 0);
        } else {
            self.emit_a_bc(Opcode.LDCONST, (uint)elem_reg, part.str_idx);
        }
        ushort idx_reg = self.alloc_reg();
        self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i);
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)idx_reg, (uint)elem_reg);
        self.free_reg(elem_reg);
        self.free_reg(idx_reg);
    }
    self.emit_a_bc(Opcode.SETALEN, (uint)tmpl_arr_reg, (uint)parts.len);

    // Create raw array (uncooked source text of each part)
    ushort raw_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)raw_arr_reg, 0, 0);

    foreach (i, part : parts) {
        ushort str_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)str_reg, part.raw_idx);
        ushort idx_reg = self.alloc_reg();
        self.emit_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i);
        self.emit_abc(Opcode.PUTPROP, (uint)raw_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit_a_bc(Opcode.SETALEN, (uint)raw_arr_reg, (uint)parts.len);

    // Set .raw property on template array, a real but non-enumerable data
    // property (ES2015 §12.2.9.3 step 8: CreateDataProperty, then step 9
    // demotes it to non-writable/non-configurable via freeze below; own
    // enumerability is fixed at creation since freeze doesn't alter it).
    {
        uint raw_key_idx = self.add_string_constant("raw");
        ushort raw_key_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.LDCONST, (uint)raw_key_reg, raw_key_idx);
        self.emit_abc(Opcode.PUTPROP_NE, (uint)tmpl_arr_reg, (uint)raw_key_reg, (uint)raw_arr_reg);
        self.free_reg(raw_key_reg);
    }

    // Both arrays are frozen, non-configurable/non-writable integrity
    // level (ES2015 §12.2.9.3 steps 10-11).
    self.emit_abc(Opcode.FREEZEOBJ, (uint)raw_arr_reg, 0, 0);
    self.free_reg(raw_arr_reg);
    self.emit_abc(Opcode.FREEZEOBJ, (uint)tmpl_arr_reg, 0, 0);

    self.emit_a_bc(Opcode.SETCONST, (uint)tmpl_arr_reg, cache_idx);

    self.patch_jump(cached_jump);

    // === Set up the call ===
    // Ensure callee is positioned so args don't overlap with live registers
    ushort first_arg = callee_reg + 2;
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }

    // Place 'this' slot
    if (obj_reg != REG_NONE) {
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)obj_reg, 0);
        self.free_reg(obj_reg);
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Place template array as first argument (callee_reg + 2)
    self.emit_abc(Opcode.LDREG, (uint)first_arg, (uint)tmpl_arr_reg, 0);
    self.free_reg(tmpl_arr_reg);

    // Place expression arguments in consecutive registers after template array
    foreach (i, reg : expr_regs) {
        ushort expected = first_arg + 1 + (ushort)i;
        if (reg != expected) {
            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)reg, 0);
            self.free_reg(reg);
        }
    }

    // Update next_reg past all arguments
    ushort total_args = 1 + (ushort)expr_regs.len;  // template array + expressions
    self.next_reg = first_arg + total_args;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    // Emit CALL: A=result, B=callee, C=arg count
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, (uint)total_args);

    return result_reg;
}

// Compute the super base register for `super.x` / `super[x]` (§13.3.7.1
// GetSuperBase): loads the enclosing method's HomeObject and derives its
// [[Prototype]] via GETPROTO, evaluated fresh on every call so a later
// mutation of the HomeObject's own [[Prototype]] (Object.setPrototypeOf) is
// observed immediately, matching the spec instead of a statically cached
// reference. HomeObject is:
//   - `__static_super__` (the constructor itself) for a static method;
//   - `__super__` (the object literal itself) for an object-literal concise
//     method/accessor -- see super_home_is_object_literal's doc comment;
//   - otherwise `__home_object__` (the class's own .prototype) for an
//     instance method, independent of whether the class has `extends` (a
//     class without extends still needs its own .prototype as HomeObject,
//     so super.x there resolves Object.prototype's members).
// These bindings are set up once, in gen_class_body / gen_object.
// Returns the register holding the super base (caller owns/frees it).
fn ushort CompilerContext.emit_super_base(&self) {
    uint home_name_idx;
    if (self.super_is_static_method) {
        home_name_idx = self.static_super_name_idx;
        if (home_name_idx == 0xFFFFFFFF) {
            home_name_idx = self.add_string_constant("__static_super__");
        }
    } else if (self.super_home_is_object_literal) {
        home_name_idx = self.super_name_idx;
        if (home_name_idx == 0xFFFFFFFF) {
            home_name_idx = self.add_string_constant("__super__");
        }
    } else {
        home_name_idx = self.home_object_name_idx;
        if (home_name_idx == 0xFFFFFFFF) {
            home_name_idx = self.add_string_constant("__home_object__");
        }
    }
    ushort home_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)home_reg, home_name_idx);
    ushort super_proto_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROTO, (uint)super_proto_reg, (uint)home_reg, 0);
    self.free_reg(home_reg);
    return super_proto_reg;
}

// ToString-coerce a template substitution value. TOSTR mutates its register in
// place, so when `reg` is a live variable's home register (a bare identifier
// read returns the home directly: a register-resident local or slot-global),
// coercing in place would corrupt the variable, e.g. `${a} ${a + b}` would
// leave `a` holding the string "10". A register below the allocation watermark
// (next_reg) aliases such a home; coerce into a fresh temp instead so the home
// stays intact. Returns the register holding the coerced string.
fn ushort CompilerContext.tostr_into_temp(&self, ushort reg) {
    if (reg < self.next_reg) {
        ushort tmp = self.alloc_reg();
        if (tmp != reg) {
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)reg, 0);
        }
        self.emit_abc(Opcode.TOSTR, (uint)tmp, 0, 0);
        return tmp;
    }
    self.emit_abc(Opcode.TOSTR, (uint)reg, 0, 0);
    return reg;
}

// Classify the value `reg` holds at the end of the instruction span
// [start, end), the producer chain of one template substitution expression.
// Walks backward from the last plain-destination writer of `reg`, recursing
// through arithmetic operands, and answers PART_DEFER only for provably
// primitive results whose ToString is pure and cannot throw. Anything outside
// the conservative allow-list (property/var loads, calls, closures, arrays,
// LDREG, dispatch) answers PART_UNKNOWN, so the analysis can never prove an
// object or symbol primitive.
fn PartKind CompilerContext.part_producer_kind(&self, uint start, uint end,
                                               ushort reg, uint depth) {
    if (depth > 3) return PartKind.PART_UNKNOWN;
    // The last writer of `reg` inside the span is the producer chain node.
    // INC/DEC mutate A in place and preserve the operand's number-ness, so
    // skipping them as writers lets the real producer be found; every other
    // non-plain-destination instruction (calls, var/property loads, arrays,
    // iterators) means an arbitrary value and answers UNKNOWN in the default.
    for (uint i = end; i > start; i--) {
        Instruction ins = self.code[i - 1];
        if (!moveelim_a_is_write(ins.op)) continue;
        if ((uint)ins.a != (uint)reg) continue;
        switch (ins.op) {
            case Opcode.LDINT:
            case Opcode.LDINTX:
                return PartKind.PART_DEFER;
            case Opcode.LDCONST: {
                uint bc = ins.get_bc();
                if (bc < self.const_count) {
                    TVal value = self.constants[bc];
                    if (value.is_string() || value.is_number()
                        || value.is_fastint() || value.is_bigint()
                        || value.is_boolean() || value.is_null()
                        || value.is_undefined()) {
                        return PartKind.PART_DEFER;
                    }
                }
                return PartKind.PART_UNKNOWN;
            }
            case Opcode.LDUNDEF:
            case Opcode.LDNULL:
            case Opcode.LDTRUE:
            case Opcode.LDFALSE:
            case Opcode.VOID:
                return PartKind.PART_DEFER;
            case Opcode.TYPEOF:
            case Opcode.TOSTR:
            case Opcode.STRJOIN:
                // typeof is always a string; TOSTR output and template
                // literal results are strings.
                return PartKind.PART_DEFER;
            case Opcode.UNP:
            case Opcode.UNM:
            case Opcode.BNOT:
                if (self.part_producer_kind(start, i - 1, (ushort)ins.b, depth + 1)
                    != PartKind.PART_DEFER) {
                    return PartKind.PART_UNKNOWN;
                }
                return PartKind.PART_DEFER;
            case Opcode.ADD:
            case Opcode.SUB:
            case Opcode.MUL:
            case Opcode.DIV:
            case Opcode.MOD:
            case Opcode.EXP:
            case Opcode.BAND:
            case Opcode.BOR:
            case Opcode.BXOR:
            case Opcode.SHL:
            case Opcode.SHR:
            case Opcode.USHR:
            case Opcode.ADDI..Opcode.USHRI: {
                // The immediate forms read B only; C is an immediate.
                ushort b_reg = (ushort)ins.b;
                ushort c_reg = (ushort)ins.c;
                if (bytecode::is_imm_form(ins.op)) {
                    if (self.part_producer_kind(start, i - 1, b_reg, depth + 1)
                        != PartKind.PART_DEFER) {
                        return PartKind.PART_UNKNOWN;
                    }
                    return PartKind.PART_DEFER;
                }
                if (self.part_producer_kind(start, i - 1, b_reg, depth + 1)
                        != PartKind.PART_DEFER
                    || self.part_producer_kind(start, i - 1, c_reg, depth + 1)
                        != PartKind.PART_DEFER) {
                    return PartKind.PART_UNKNOWN;
                }
                // Two deferrable operands (strings, numbers, bigints,
                // booleans, null, undefined) always yield a primitive.
                return PartKind.PART_DEFER;
            }
            case Opcode.EQ:
            case Opcode.NEQ:
            case Opcode.SEQ:
            case Opcode.SNEQ:
            case Opcode.LT:
            case Opcode.LE:
            case Opcode.GT:
            case Opcode.GE:
            case Opcode.IN:
            case Opcode.INSTANCEOF:
            case Opcode.LNOT:
                return PartKind.PART_DEFER;
            default:
                return PartKind.PART_UNKNOWN;
        }
    }
    return PartKind.PART_UNKNOWN;
}

// Parse-time validation of a regexp literal (ES §12.9.3 early errors): the pattern must compile
// under the literal's flags. `raw` is the "/pattern/flags" text. Flags must be valid,
// non-duplicate, and u/v mutually exclusive. Returns the error message, or an empty string for a
// valid literal. Splitting mirrors the VM's NEWREGEXP handler.
fn String regexp_literal_error(char[] raw) {
    usz len = raw.len;
    if (len < 2 || raw[0] != '/') return "";

    usz end_slash = len - 1;
    while (end_slash > 0 &&
           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
        end_slash--;
    }
    if (end_slash == 0 || raw[end_slash] != '/') return "";

    char[] pattern_data = raw[1..end_slash - 1];
    char[] flag_data = {};
    if (end_slash + 1 < len) {
        flag_data = raw[end_slash + 1..len - 1];
    }

    int flags = 0;
    uint seen = 0;
    foreach (f : flag_data) {
        uint bit;
        switch (f) {
            case 'g': bit = 1;
            case 'i': bit = 2;    flags |= re_bindings::RE_FLAG_IGNORECASE;
            case 'm': bit = 4;    flags |= re_bindings::RE_FLAG_MULTILINE;
            case 's': bit = 8;    flags |= re_bindings::RE_FLAG_DOTALL;
            case 'u': bit = 16;   flags |= re_bindings::RE_FLAG_UNICODE;
            case 'y': bit = 32;   flags |= re_bindings::RE_FLAG_STICKY;
            case 'd': bit = 64;   flags |= re_bindings::RE_FLAG_INDICES;
            case 'v': bit = 128;  flags |= re_bindings::RE_FLAG_UNICODE_SETS;
            default:
                return "invalid regexp flag";
        }
        if ((seen & bit) != 0) {
            return "duplicate regexp flag";
        }
        seen |= bit;
    }
    if ((seen & 16) != 0 && (seen & 128) != 0) {
        return "regexp flags u and v are mutually exclusive";
    }

    // The runtime NEWREGEXP compiles the INTERNED pattern, which str_intern
    // normalizes to CESU-8 (astral chars become surrogate pairs). Validate
    // the same bytes, or astral literals get rejected here that the runtime
    // accepts. CESU-8 output is at most 1.5x the UTF-8 input.
    usz plen = pattern_data.len;
    char* buf = (char*)alloc::malloc_try(mem, (sz)(plen * 2 + 1)) ?? null;
    if (buf == null) return "";
    defer mem::free(buf);
    if (hstring::has_raw_utf8_astral(pattern_data)) {
        plen = (usz)hstring::normalize_to_cesu8(pattern_data, buf[0..plen * 2]);
    } else {
        mem::copy(buf, pattern_data.ptr, (sz)(plen));
    }
    buf[plen] = 0;
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(buf, plen, flags, &error_buf, 128);
    if (compiled == null) {
        return "invalid regular expression";
    }
    re_bindings::re_free(compiled);
    return "";
}

// Emit bytecode for a for-of loop.  The iterable expression has already been
// evaluated into `iter_reg` and the RParen was consumed.
// Uses the ES6 iterator protocol: Symbol.iterator → .next() → {value, done}.
fn void? CompilerContext.emit_forof_loop(&self, char[] var_name, ushort iter_reg, uint saved_scope, ushort saved_reg, bool is_lexical, bool is_const, bool is_bare, bool is_await = false, uint ast_body = 0) {
    // Declare loop variable register. (Per-iteration lexical env, §14.7.5.6, is
    // handled uniformly inside emit_forof.)
    ushort loop_var;
    bool reg_resident = false;
    if (is_bare) {
        // Bare `for (b of ...)` assigns to an existing binding. If that binding
        // is a register-cached local, bind straight into its home register so
        // the body's register read sees the value (PUTVAR alone desyncs it).
        if (!self.is_global) {
            if (try home = self.resolve_var(var_name)) {
                loop_var = home;
                reg_resident = true;
            } else {
                loop_var = self.alloc_reg();
            }
        } else if (try slot_home = self.resolve_slot_global(var_name)) {
            // A top-level `var` proven register-resident by
            // resolution lives in a home register, not the
            // global object. `for (x of ...)` / `for ((x) of ...)` must write
            // straight into that home; a PUTVAR would update the env slot while
            // the body reads the stale register, so x stays undefined.
            loop_var = slot_home;
            reg_resident = true;
        } else {
            loop_var = self.alloc_reg();
        }
    } else {
        ScopeKind kind = is_const ? CONST : (is_lexical ? LET : VAR);
        self.check_var_lex_conflict(var_name, kind)!;
        loop_var = self.declare_binding_var(var_name, kind);
    }

    uint name_idx = self.add_string_constant(var_name);

    ForOfHead head;
    head.kind = IDENT;
    head.id_reg = loop_var;
    head.id_name_idx = name_idx;
    head.id_is_bare = is_bare;
    head.id_reg_resident = reg_resident;
    head.is_lexical = is_lexical;
    head.is_const = is_const;
    // B.3.5: a sloppy catch body's `var x of ...` reuses the catch
    // parameter's binding when the parameter is a BindingIdentifier, and the
    // catch's lex_env sits above the var_env DECLVAR would write to. Same
    // chain-walk case as a captured hoisted `var` (env-authoritative
    // store). Only set the chain-walk bit when the existing binding is
    // env-resident; an uncaptured hoisted `var` stays DECLVAR because its
    // register-resident semantics would not survive PUTVAR's source-register
    // clear.
    head.id_walk_chain = false;
    if (!is_bare && !is_lexical && !is_const) {
        if (try _r = self.find_local_reg(var_name)) {
            if (self.is_existing_local_env_resident(var_name)) {
                head.id_walk_chain = true;
            }
        }
    }
    self.emit_forof(head, iter_reg, saved_scope, saved_reg, is_await, ast_body)!;
}
