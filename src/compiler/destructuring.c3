module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::hbigint;
import std::io;
import std::collections::list;

// ============================================================================
// Destructuring patterns (array and object)
// ============================================================================

// True when a property-key token may also serve as the *target* of an object
// pattern's shorthand form (`{a}` / `{a = d}`), where the key doubles as an
// IdentifierReference (assignment patterns) or BindingIdentifier (binding
// patterns).
//
// Per ES2015 §13.15.5.1 / §13.3.3, the shorthand's target is an
// `Identifier: IdentifierName but not ReservedWord`, so `{ extends }`,
// `{ var }` and `{ default }` are early SyntaxErrors even though those same
// words are perfectly legal as *keys* in the `{ extends: t }` long form.
// Escaped spellings (`{ var }`) are covered for free: ES2024 §12.6.1
// makes the lexer resolve an escaped reserved word to its keyword token, so
// they arrive here under the same TokenType as the literal spelling.
//
// `await` is reserved only inside a module / async function ([Await] scope);
// outside those it is a plain identifier and the shorthand is legal.
//
// A shorthand key doubles as a BindingIdentifier, so it must be usable
// as an IdentifierReference in this context: a plain Identifier, `await`
// where it is not reserved, or sloppy non-generator `yield` (§13.1.1).
// This mirrors the object-*literal* shorthand gate in `object_literal`
// (expressions.c3), which already rejects the reserved-word forms; the
// pattern collectors below route reserved words through
// `destructuring_property_key` and so need this check to match it.
fn bool CompilerContext.shorthand_key_is_identifier_ref(&self, TokenType tt) {
    if (tt == TokenType.IDENTIFIER || self.await_is_identifier(tt)) return true;
    if ((tt == TokenType.LET || tt == TokenType.STATIC) && !self.is_strict) return true;
    return tt == TokenType.YIELD && !self.is_strict && !self.is_user_generator && !self.forbid_yield;
}

// Parse a property key in a destructuring binding pattern.
// Per ES2015 §13.3.3.7 the property key can be an IdentifierName, a string
// literal, a numeric literal, or a computed key. Reserved words are
// allowed as binding keys (mirroring object-literal property syntax), they
// are stored under their keyword spelling in the constant pool, so the
// runtime property lookup matches the lexical key.
//
// Returns the key as a `char[]` slice (backed by the token's str_value;
// valid until the lexer advances past the consumed token).
fn char[]? CompilerContext.destructuring_property_key(&self) {
    TokenType tt = self.peek_type();
    // Identifier or reserved-word key
    if (tt == TokenType.IDENTIFIER) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // String literal key (e.g. {"a b": c})
    if (tt == TokenType.STRING) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // Numeric literal key (e.g. {1: c}), ConvertToPropertyKey stores as string
    if (tt == TokenType.NUMBER) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // BigInt literal key (e.g. {1n: c}), ES2020 PropertyName: NumericLiteral,
    // the key is ToString(NumericValue(NumericLiteral)). Parse+format at
    // compile time (destructuring keys are static constants, not runtime
    // TOPROPKEY targets) and intern so the returned slice outlives this call.
    if (tt == TokenType.BIGINT) {
        Token t = self.advance()!;
        Heap* hp = (Heap*)self.heap;
        hbigint::HBigInt*? parsed = hbigint::parse_bigint_literal(hp, t.str_value);
        if (catch parsed) return COMPILE_ERROR~;
        char[48] buf;
        char* dheap;
        char[] digits = hbigint::hbigint_to_decimal(hp, parsed, buf[..], &dheap);
        defer if (dheap != null) hp.free((void*)dheap);
        HString* hs = hp.str_intern(digits);
        if (hs == null) return COMPILE_ERROR~;
        return hs.get_data();
    }
    // Reserved word (keyword) key, only when a keyword has a string spelling.
    // The lexer's keyword tokens carry str_value only for the contextual
    // keywords set up as object-literal keys (default, if, etc.); for plain
    // keywords we extract the canonical spelling.
    char[] kw_str = lexer::keyword_to_string(tt);
    if (kw_str.len > 0) {
        // A PropertyName is an IdentifierName, so an escaped spelling names
        // the property (`var { break: x } = o`); in the shorthand form
        // the key doubles as a BindingIdentifier, which is Identifier grammar
        // too, so the escape stays legal there as well.
        self.advance(true)!;
        return kw_str;
    }
    // TypeScript accepts `#name` as a destructuring-pattern key (tsc passes
    // it through verbatim even though private destructuring has no runtime
    // semantics). In ts_mode lower it to the ordinary string key "#name" so
    // conformant files compile; the read then behaves like any other absent
    // property. Outside ts_mode it stays a SyntaxError, as does the
    // shorthand form (shorthand_key_is_identifier_ref rejects HASH_IDENT,
    // since `#foo` is not a BindingIdentifier).
    if (tt == TokenType.HASH_IDENT && self.lexer.ts_mode) {
        Token ht = self.advance()!;
        Heap* hhp = (Heap*)self.heap;
        usz hlen = ht.str_value.len + 1;
        if (hlen <= 4097) {
            char[4097] hbuf;
            hbuf[0] = '#';
            for (usz hi = 0; hi < ht.str_value.len; hi++) hbuf[hi + 1] = ht.str_value[hi];
            HString* hhs = hhp.str_intern(hbuf[:hlen]);
            if (hhs == null) return COMPILE_ERROR~;
            return hhs.get_data();
        }
        char* hmem = (char*)alloc::malloc_try(mem, (sz)hlen) ?? null;
        if (hmem == null) return COMPILE_ERROR~;
        hmem[0] = '#';
        for (usz hi = 0; hi < ht.str_value.len; hi++) hmem[hi + 1] = ht.str_value[hi];
        HString* hhs2 = hhp.str_intern(hmem[:hlen]);
        mem::free(hmem);
        if (hhs2 == null) return COMPILE_ERROR~;
        return hhs2.get_data();
    }
    self.record_error("expected a property name in destructuring pattern");
    return COMPILE_ERROR~;
}

// The early errors on the BoundNames of a pattern that introduces lexical
// bindings: no name may repeat (ES2024 §14.3.1.1 LexicalDeclaration, §14.7.5.1
// ForDeclaration, §14.15.1 CatchParameter), in any mode, while a `var`
// pattern allows repeats. A LexicalDeclaration or ForDeclaration also may not
// bind `let`, which a CatchParameter may in sloppy code. The collectors
// already applied the restricted-name rules to each leaf.
fn void? CompilerContext.check_lexical_bound_names(&self, DestructBind[] binds, bool forbid_let = true) {
    foreach (i, &bi : binds) {
        if (bi.is_synthetic) continue;
        if (forbid_let && str_eq(self.bind_name(bi), "let")) {
            return self.fail("'let' cannot be a lexically bound name")~;
        }
        // Interning gives each distinct name one constant-pool index.
        foreach (&bj : binds[i + 1..]) {
            if (!bj.is_synthetic && bj.name_idx == bi.name_idx) {
                return self.fail("duplicate binding in lexical declaration")~;
            }
        }
    }
}

// Collect a declaration's pattern, starting at its '[' or '{', and declare
// every leaf in `kind`, returning whether it is an object pattern. A lexical
// pattern is checked before anything is declared, so a failure leaves no
// partial bindings behind.
fn bool? CompilerContext.declare_pattern(&self, DestructBinds* binds, ScopeKind kind, bool is_lexical) {
    // A declaration is not a function-parameter list. `collect_*_param_binds`
    // is shared with the parameter-list path and gates `await`/`yield` out of
    // default values while `in_formal_params` is set, but a declaration's
    // defaults are AssignmentExpressions (ES2018 §13.3.3), which DO permit
    // await in async contexts and yield in generator contexts.
    bool saved_in_fp = self.in_formal_params;
    self.in_formal_params = false;
    defer self.in_formal_params = saved_in_fp;

    // The source register (arg_idx) of top-level binds is patched once the
    // value is known; nested binds read from their parent group instead.
    bool is_object = self.peek_type() == TokenType.LBRACE;
    self.advance()!; // consume '[' or '{'
    if (is_object) {
        self.collect_obj_param_binds(binds, 0, 0xFFFF)!;
    } else {
        self.collect_arr_param_binds(binds, 0, 0xFFFF)!;
    }
    if (is_lexical) self.check_lexical_bound_names(binds.array_view())!;
    foreach (&b : binds) {
        if (b.is_synthetic) continue;
        char[] name = self.bind_name(b);
        self.check_var_lex_conflict(name, kind)!;
        b.binding_reg = self.declare_binding_var(name, kind);
    }
    return is_object;
}

// Parse a destructuring declaration: `[a, b, ...rest] = rhs` or
// `{a, b: c, x = d} = rhs`, starting at the pattern's '[' or '{'.
//
// Uses the ES2015 §13.3.3 iterator protocol via the shared, recursive
// `emit_destruct_bindings` emitter, the same machinery the function-parameter
// path uses. This makes statement-level destructuring work for any iterable
// (generators, custom iterables), at arbitrary nesting depth, not just Arrays.
// See plan 044; mirrors QuickJS's OP_for_of_start/OP_for_of_next lowering.
//
// Declares every leaf in `kind` and, when `out_names` is set, appends each leaf
// name (interned, so it outlives the pattern) for callers that register the
// names elsewhere: `export var {a} = o` exports them, and a for-loop head gives
// them per-iteration environments.
fn void? CompilerContext.destructure_declaration(&self, ScopeKind kind, bool is_lexical, bool is_const,
                                                  List{char[]}* out_names = null) {
    DestructBinds binds = { .allocator = mem };
    defer free_destruct_binds(&binds);
    ushort pre_decl_next = self.next_reg;
    bool is_object = self.declare_pattern(&binds, kind, is_lexical)!;
    if (out_names) {
        foreach (&b : binds) {
            if (!b.is_synthetic) out_names.push(self.bind_name(b));
        }
    }

    if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;

    // No initializer (`var [a, b];`): bind everything to undefined. Only a
    // for-in/of head accepts this, and RequireObjectCoercible does not apply
    // without a source value. A `const` pattern always requires one
    // (ES2024 §13.3.1).
    if (!self.match(TokenType.ASSIGN)) {
        if (is_const) return self.fail("const declaration requires an initializer")~;
        foreach (&b : binds) {
            if (b.is_synthetic) continue;
            self.emit_abc(Opcode.LDUNDEF, (uint)b.binding_reg, 0, 0);
            self.emit_var_store(b.binding_reg, b.name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS (after all bindings declared, so their regs are below the
    // RHS reg, keeping loop-carried collectors safe from CALL frame overlay).
    // Save the watermark so all destructuring temporaries (RHS + iterator
    // state + per-element scratch) are released together afterward, preventing
    // register drift across successive destructuring statements.
    ushort saved_next = self.next_reg;
    ushort rhs_reg = self.assignment_expr()!;

    self.emit_destructure(binds.array_view(), is_object, rhs_reg, DestructStoreMode.DECLARE,
                          is_lexical, is_const);

    self.free_regs_to(saved_next);

    // At global scope, var bindings are env-resident (resolve_var skips the
    // global scope), so their registers are only needed as the DECLVAR source.
    // Free them to prevent register drift, matching the simple-declaration path.
    if (self.is_global && !is_lexical) {
        self.free_regs_to(pre_decl_next);
    }
}

// ============================================================================
// Destructuring ASSIGNMENT (without let/const/var)
// ============================================================================

// Scan ahead from the current `{` or `[` token to determine whether it begins
// a MemberExpression primary (e.g. `{}.x`, `{}[key]`, `[1,2][0]`) rather
// than a nested destructuring pattern.
//
// Scans the raw source by creating a disposable copy of the lexer, skipping
// past the outermost balanced brace/bracket, then checking the token that
// immediately follows. Returns true if `.`, `[`, or `(` follows the closing
// bracket, meaning the caller should treat it as a full LHS expression
// rather than a nested sub-pattern.
//
// The actual lexer state is never modified; the scan is purely speculative.
fn bool CompilerContext.primary_is_member_target(&self) {
    // Determine the open/close bracket pair from the upcoming token.
    TokenType open_tt  = self.peek_type();
    TokenType close_tt = (open_tt == TokenType.LBRACE)
        ? TokenType.RBRACE : TokenType.RBRACKET;

    // Make a cheap copy of the lexer so we can lex ahead without side-effects.
    // Preserve the lexer state exactly (including any buffered lookahead and
    // pushback tokens) so that `scan.next_token()` correctly yields the `{`
    // or `[` that peek_type() already saw.
    Lexer scan = *self.lexer;
    // Also copy the compiler pushback stack, but we do not use it in this
    // speculative scan (we go directly through the Lexer copy).  Clear
    // pushed_back so the Lexer-level pushback is the only source.
    scan.has_pushed_back = false;

    // Consume the opening bracket.
    Token? open_opt = scan.next_token();
    if (catch _err1 = open_opt) return false;

    // Scan past the balanced bracket pair, tracking nesting depth.
    int depth = 1;
    while (depth > 0) {
        Token? t_opt = scan.next_token();
        if (catch _err2 = t_opt) return false;
        Token t = t_opt;
        if (t.type == TokenType.EOF_TOKEN) return false;
        if (t.type == open_tt)  depth++;
        if (t.type == close_tt) depth--;
    }

    // Check what follows the closing bracket.
    Token? next_opt = scan.next_token();
    if (catch _err3 = next_opt) return false;
    Token next = next_opt;
    return (next.type == TokenType.DOT
         || next.type == TokenType.LBRACKET
         || next.type == TokenType.LPAREN
         || next.type == TokenType.OPT_CHAIN);
}

// Parse a DestructuringAssignmentTarget, any LeftHandSideExpression valid
// as an assignment target (§13.15.5). Returns true when the target is a
// A parsed destructuring assignment target: either a member expression, whose
// evaluated object and key wait in registers for the store, or a plain
// identifier, named by its constant-pool index.
struct AssignTarget {
    bool is_member;
    // Member targets only.
    ushort obj_reg;
    ushort key_reg;
    // `super.x` / `super[k]`, whose store is PUTPROP_SUPER: obj_reg holds the
    // home object's prototype, where the property walk starts, but a setter
    // found there runs with the current `this` as its receiver (§13.15.2).
    bool is_super;
    // Identifier targets only.
    uint name_idx;
}

// member expression (`a.b`, `a[i]`, `{}[f()]`, etc.); false when it is a
// plain identifier.
//
// For a member target it emits code evaluating the object and key into fresh
// registers, for a later PUTPROP; for an identifier target it emits nothing
// and reports the name's constant-pool index.
//
// When the next token is an IDENTIFIER not followed by `.`, `[`, or `(`,
// we consume it cheaply without emitting a GETVAR, assignment patterns
// only write to the target, never read from it.  For anything more complex
// (member chains starting with any primary, `new`, etc.) we call
// `postfix_expr` in lhs_mode and NOP the trailing GETPROP.
fn AssignTarget? CompilerContext.parse_assign_target_lhs(&self) {
    AssignTarget out;
    out.name_idx = 0xFFFFFFFF;
    out.obj_reg = 0xFFFF;
    out.key_reg = 0xFFFF;
    // Fast path: plain identifier target, no code emission needed.
    // We only commit to the fast path when the very next token after the
    // identifier is NOT a property/call/index accessor, ensuring that
    // `a.b`, `a[i]`, `a()` etc. fall through to the full expression path.
    // Sloppy non-generator `yield`, and `let`/`static` in sloppy code, are
    // Identifiers here too (§13.1.1).
    TokenType head_tt = self.peek_type();
    bool head_is_ctx_ident = (head_tt == TokenType.YIELD
            && !self.is_strict && !self.is_user_generator && !self.forbid_yield)
        || ((head_tt == TokenType.LET || head_tt == TokenType.STATIC) && !self.is_strict);
    if (head_tt == TokenType.IDENTIFIER || head_is_ctx_ident) {
        // Peek at the token after the identifier without consuming it.
        // Lexer state snapshot so we can look one token ahead.
        uint   snap_pos  = self.lexer.pos;
        uint   snap_line = self.lexer.line;
        uint   snap_col  = self.lexer.col;
        Token  snap_cur  = self.lexer.current;
        Token  snap_lk   = self.lexer.lookahead;
        bool   snap_hlk  = self.lexer.has_lookahead;
        Token  snap_pb   = self.lexer.pushed_back;
        bool   snap_hpb  = self.lexer.has_pushed_back;
        bool   snap_slt  = self.lexer.seen_line_term;
        uint   snap_pbc  = self.pushback_count;
        Token[4] snap_pbs = self.pushback_stack;

        Token ident_tok = self.advance(true)!;  // consume identifier

        // Read the next token to check for member/call accessors.
        Token? next_opt = self.lexer.next_token();
        TokenType next_tt = TokenType.EOF_TOKEN;
        if (try next = next_opt) { next_tt = next.type; }

        bool is_accessor = (next_tt == TokenType.DOT
            || next_tt == TokenType.LBRACKET
            || next_tt == TokenType.LPAREN
            || next_tt == TokenType.OPT_CHAIN);

        // Restore lexer state (put everything back).
        self.lexer.pos  = snap_pos;  self.lexer.line = snap_line;
        self.lexer.col  = snap_col;  self.lexer.current = snap_cur;
        self.lexer.lookahead = snap_lk; self.lexer.has_lookahead = snap_hlk;
        self.lexer.pushed_back = snap_pb; self.lexer.has_pushed_back = snap_hpb;
        self.lexer.seen_line_term = snap_slt;
        self.pushback_count = snap_pbc; self.pushback_stack = snap_pbs;

        if (!is_accessor) {
            // True simple identifier: consume the token and return the name.
            Token id = self.advance()!;
            out.name_idx = self.add_string_constant(id.str_value);
            return out;
        }
        // Falls through to the full expression path below.
    }

    // General path: parse the full LHS expression (member chain, new, etc.)
    // using lhs_mode so member_expr keeps obj/key registers live.
    // member_expr always emits a trailing GETPROP; we NOP it immediately to
    // avoid invoking a property getter on the assignment target.
    bool saved_lhs = self.lhs_mode;
    self.lhs_mode = true;
    self.member.clear();
    self.last_was_getvar  = false;

    ushort lhs_result = self.postfix_expr()!;

    self.lhs_mode = saved_lhs;

    // An AssignmentExpression (or UpdateExpression) has AssignmentTargetType
    // ~invalid~ (§13.15.1), so a parenthesized assignment such as `(b = 7)` is
    // not a destructuring target even though its reference markers survive.
    // The verdict is stamped by assignment_expr after the inner parse.
    if (self.last_target_invalid) {
        self.free_reg(lhs_result);
        return self.fail("invalid assignment target in destructuring pattern")~;
    }

    if (self.last_was_member()) {
        // NOP the trailing GETPROP so we do not invoke a getter.
        if (self.code_count > 0) {
            uint last = self.code_count - 1;
            if (self.code[last].op == Opcode.GETPROP || self.code[last].op == Opcode.GETPROP_CACHE) {
                self.code[last] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            }
        }
        self.free_reg(lhs_result);
        out.is_member = true;
        out.obj_reg   = self.member_obj();
        out.key_reg   = self.member_prop();
        out.is_super  = self.member_is_super();
        self.member.clear();
        self.call_prop_obj_reg = REG_NONE;
        return out;
    }

    if (self.last_was_getvar) {
        // Identifier that was reached through a complex path (e.g. after
        // `new` or other non-member primaries that still set last_was_getvar).
        out.name_idx = self.last_getvar_name_idx;
        self.free_reg(lhs_result);
        self.last_was_getvar = false;
        return out;
    }

    if (self.last_was_local_var && self.last_lhs_name_len > 0) {
        // Register-resident local reached through a complex path, the common
        // case being a parenthesized target (`[(a), b] = ...`). primary_expr
        // captured the name, so resolve the target by name exactly as the
        // identifier fast path above does.
        out.name_idx = self.add_string_constant(self.last_lhs_name_buf[:self.last_lhs_name_len]);
        self.free_reg(lhs_result);
        self.last_was_local_var = false;
        return out;
    }

    // Not a valid assignment target.
    return self.fail("invalid assignment target in destructuring pattern")~;
}

// Parse a leaf assignment target into a DestructBind, deferring member
// targets. Per ES2022 §13.15.5 the target lref is evaluated after the
// iterator is opened, so for member expressions the collection-time parse
// only advances the lexer, its code and registers are discarded, and a
// lexer snapshot is stored for emit_deferred_target to re-parse inside the
// IteratorClose guard.
fn void? CompilerContext.collect_assign_target(&self, DestructBind* bind)
{
    DeferredTarget* snap = (DeferredTarget*)alloc::malloc_try(mem, (sz)(DeferredTarget::size)) ?? null;
    snap.lexer = *self.lexer;
    snap.pushback = self.pushback_stack;
    snap.pushback_count = self.pushback_count;
    uint pre_code = self.code_count;
    ushort pre_reg = self.next_reg;

    AssignTarget? tgt_res = self.parse_assign_target_lhs();
    if (catch err = tgt_res) {
        mem::free(snap);
        return err~;
    }
    AssignTarget tgt = tgt_res;
    bool is_member = tgt.is_member;
    uint tgt_name = tgt.name_idx;

    // AssignmentElement's target must be a valid simple assignment target
    // (ES2024 §13.15.1): in strict code `eval`, `arguments` and the reserved
    // words are not, so `[eval] = v` / `[yield] = v` are early SyntaxErrors
    // exactly as the non-pattern `eval = v` already is. Only identifier
    // targets can offend — a member expression (`o.eval`) is always valid.
    // This is the one point every leaf assignment target passes through, so
    // array elements, object properties, rest targets and nested patterns are
    // all covered here rather than at N call sites.
    if (!is_member) {
        HString* nhs = (HString*)self.constants[tgt_name].get_heapptr();
        if (is_restricted_name(nhs.get_data(),
                               self.await_reserved_here(),
                               self.is_generator || self.forbid_yield, strict: self.lexer.reserved_words_strict)) {
            mem::free(snap);
            return COMPILE_ERROR~;
        }
    }

    bind.name_idx         = tgt_name;
    bind.is_member_target = is_member;
    bind.member_obj_reg   = tgt.obj_reg;
    bind.member_prop_reg  = tgt.key_reg;
    if (is_member) {
        self.code_count = pre_code;
        self.free_regs_to(pre_reg);
        bind.deferred_target = snap;
    } else {
        mem::free(snap);
    }
}

// Re-parse and emit a member target deferred by collect_assign_target.
// Called by emit_destruct_bindings inside the IteratorClose guard. The
// evaluated object/key land in fresh registers at the current watermark and
// are copied down into the bind's pre-allocated persistent pair (below every
// iterator/push callee window, so they survive the protocol CALLs up to the
// final PUTPROP); the parse temporaries are then released.
//
// For private field targets (this.#field), the brand check (CHK_BRAND) is
// deferred: emit_private_access loads the brand symbol but skips the check.
// The bind's is_private_target flag and deferred_brand_* fields carry the
// state so emit_destruct_bindings can emit the CHK_BRAND after GetV.
fn void CompilerContext.emit_deferred_target(&self, DestructBind* bind)
{
    DeferredTarget* snap = bind.deferred_target;
    Lexer saved = *self.lexer;
    Token[4] saved_pb = self.pushback_stack;
    uint saved_pbc = self.pushback_count;
    self.swap_lexer_preserving_error(snap.lexer);
    self.pushback_stack = snap.pushback;
    self.pushback_count = snap.pushback_count;
    defer {
        self.swap_lexer_preserving_error(saved);
        self.pushback_stack = saved_pb;
        self.pushback_count = saved_pbc;
        bind.deferred_target = null;
        mem::free(snap);
    }

    // Enable deferred brand check: for private field targets, emit_private_access
    // loads the brand symbol but skips CHK_BRAND. We detect the private target
    // after parsing by checking deferred_brand_reg. The brand register itself
    // is pre-allocated (bind.private_brand_reg, from emit_destruct_bindings's
    // pre-scan) and handed to emit_private_access via deferred_brand_reg_hint.
    // It must land below the source property's upcoming GETPROP result
    // register, or a getter triggered while reading the source clobbers it
    // (invoke_getter writes its callee/this pair at [result_reg,
    // result_reg + 1] before the call even starts) before the deferred
    // CHK_BRAND runs.
    self.defer_brand_check = true;
    self.deferred_brand_reg = 0xFFFF;
    self.deferred_brand_name_c = 0xFF;
    self.deferred_brand_obj_reg = 0xFFFF;
    self.deferred_brand_reg_hint = bind.private_brand_reg;

    ushort pre_reg = self.next_reg;
    AssignTarget? tgt_res = self.parse_assign_target_lhs();
    if (catch tgt_res) {
        // Unreachable: the same token stream parsed successfully at collection.
        self.defer_brand_check = false;
        self.deferred_brand_reg_hint = 0xFFFF;
        self.free_reg(bind.private_brand_reg);
        return;
    }
    self.deferred_brand_reg_hint = 0xFFFF;

    // Check if a brand check was deferred (private field target).
    if (self.deferred_brand_reg != 0xFFFF) {
        bind.is_private_target = true;
        // deferred_brand_reg equals bind.private_brand_reg (the hint was
        // honoured), already the pre-allocated persistent register, so no
        // further protection is needed past this point. The CHK_BRAND's
        // object operand is bind.member_obj_reg (set below via LDREG), not
        // self.deferred_brand_obj_reg (the parse-time temp `this` register,
        // unsafe to read after the source GETPROP's getter call, see
        // DestructBind's doc comment).
        bind.private_brand_name_c = self.deferred_brand_name_c;

        // Strip the trailing GETPROP_PRIVATE emitted by member_expr while
        // parsing `this.#field`.  The read result is unused for the
        // assignment target (PUTPROP stores the source value) AND its brand
        // check (walk-chain → PrivateFieldFind) fires BEFORE we have evaluated
        // the source's GetV, meaning `({a: this.#field} = src)` would throw
        // out of order if src.a's getter is meant to side-effect-install
        // the private field per ES2022 §13.15.5.6.  Leave CHK_BRAND to
        // emit_destruct_bindings (which places it AFTER the source GetV).
        if (self.code_count > 0
            && self.code[self.code_count - 1].op == Opcode.GETPROP_PRIVATE) {
            self.code_count--;
        }
    } else {
        bind.is_private_target = false;
        // Not a private target after all, release the reserved slot.
        self.free_reg(bind.private_brand_reg);
    }
    self.defer_brand_check = false;
    AssignTarget tgt = tgt_res;
    bind.is_super_target = tgt.is_super;

    self.emit_abc(Opcode.LDREG, (uint)bind.member_obj_reg, (uint)tgt.obj_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)bind.member_prop_reg, (uint)tgt.key_reg, 0);
    self.free_regs_to(pre_reg);
    // bind.private_brand_reg (when is_private_target) is a persistent
    // register allocated in emit_destruct_bindings's pre-scan, well below
    // pre_reg, free_regs_to(pre_reg) above cannot reclaim it. Defensive
    // no-op guard kept in case a future caller passes a lower pre_reg.
    if (bind.is_private_target && self.next_reg <= bind.private_brand_reg) {
        self.next_reg = (ushort)(bind.private_brand_reg + 1);
    }
}

// Re-parse and emit a computed property key deferred by
// collect_obj_assign_binds. Called by emit_destruct_bindings at the point of
// use (immediately before the GETPROP that reads the property), so a
// computed key such as `{[sourceKey()]: t}` evaluates after the RHS per
// ES2022 §13.15.5.3, not before it. The evaluated key value lands in the
// bind's pre-allocated persistent register (bind.computed_key_reg).
fn void CompilerContext.emit_deferred_computed_key(&self, DestructBind* bind)
{
    DeferredTarget* snap = bind.deferred_computed_key;
    Lexer saved = *self.lexer;
    Token[4] saved_pb = self.pushback_stack;
    uint saved_pbc = self.pushback_count;
    self.swap_lexer_preserving_error(snap.lexer);
    self.pushback_stack = snap.pushback;
    self.pushback_count = snap.pushback_count;
    defer {
        self.swap_lexer_preserving_error(saved);
        self.pushback_stack = saved_pb;
        self.pushback_count = saved_pbc;
        bind.deferred_computed_key = null;
        mem::free(snap);
    }

    ushort pre_reg = self.next_reg;
    ushort? key_expr_res = self.assignment_expr();
    if (catch key_expr_res) {
        // Unreachable: the same token stream parsed successfully at collection.
        return;
    }
    ushort key_val_reg = key_expr_res;
    self.emit_abc(Opcode.LDREG, (uint)bind.computed_key_reg, (uint)key_val_reg, 0);
    // Per ES2022 §12.15.5.2 step 1, PropertyName evaluation (which includes
    // ToPropertyKey for a ComputedPropertyName, §13.2.5.5) happens here, as
    // its own step, before KeyedDestructuringAssignmentEvaluation evaluates
    // the (possibly deferred) AssignmentTarget. Coerce now so `sourceKey`'s
    // `.toString()`/`Symbol.toPrimitive` runs at this point rather than later
    // when GETPROP reads the source property.
    self.emit_abc(Opcode.TOPROPKEY, (uint)bind.computed_key_reg, 0, 0);
    self.free_regs_to(pre_reg);
}

// Collect an array assignment pattern into the shared DestructBind model.
// Targets may be identifiers or member expressions (§13.15.5
// DestructuringAssignmentTarget = LeftHandSideExpression), at the top level,
// in rest, and inside nested array/object patterns, alongside defaults and
// elision holes. Member targets are deferred (see collect_assign_target).
// The '[' has already been consumed; this consumes its own ']'.
fn void? CompilerContext.collect_arr_assign_binds(&self, DestructBinds* binds, ushort parent_idx = 0xFFFF)
{
    ushort elem_idx = 0;

    // `[]` binds nothing but still performs GetIterator and IteratorClose, so
    // it gets a bind of its own -- see is_empty_pattern. Without one the
    // pattern emits no code and a non-iterable RHS is silently accepted.
    if (self.check(TokenType.RBRACKET)) {
        self.add_bind(binds, {
            .arg_idx = 0xFFFF,
            .parent_idx = parent_idx,
            .is_synthetic = true,
            .is_empty_pattern = true,
        })!;
    }

    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        // Elision / hole: `, ,` skips an iterator position. Record a hole so
        // emit_destruct_bindings calls IteratorStep at this position per
        // IteratorBindingInitialization §13.3.3 (matching collect_arr_param_binds).
        if (self.match(TokenType.COMMA)) {
            self.add_bind(binds, {
                .index = elem_idx,
                .arg_idx = 0xFFFF,
                .parent_idx = parent_idx,
                .is_synthetic = true,
                .is_hole = true,
            })!;
            elem_idx++;
            continue;
        }

        // Rest element: `...target`
        if (self.match(TokenType.ELLIPSIS)) {
            // Nested rest pattern: `...[a, b]` or `...{a}`, but only when
            // the `{`/`[` is not a MemberExpression primary like `...{}.x`.
            if ((self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET))
                && !self.primary_is_member_target()) {
                bool is_obj = self.check(TokenType.LBRACE);
                ushort synth_idx = self.add_bind(binds, {
                    .key_idx = 0xFFFF,  // rest synthetic
                    .index = elem_idx,
                    .arg_idx = 0xFFFF,
                    .parent_idx = parent_idx,
                    .is_synthetic = true,
                })!;
                self.advance()!;  // consume '{' or '['
                if (is_obj) {
                    self.collect_obj_assign_binds(binds, synth_idx)!;
                } else {
                    self.collect_arr_assign_binds(binds, synth_idx)!;
                }
            } else {
                DestructBind b;
                self.collect_assign_target(&b)!;
                b.key_idx = 0xFFFF;  // rest sentinel
                b.index = elem_idx;
                b.arg_idx = 0xFFFF;
                b.parent_idx = parent_idx;
                self.add_bind(binds, b)!;
            }

            // AssignmentRestElement must be the last element of an
            // ArrayAssignmentPattern (ES2022 §13.15.5): neither a further
            // element nor a trailing comma/elision may follow it, so
            // `[...x,] = v` and `[...x, y] = v` are early SyntaxErrors.
            // (A trailing comma IS legal without a rest: `[a,] = v`.)
            if (self.check(TokenType.COMMA)) return COMPILE_ERROR~;
            break;
        }

        // Nested pattern: `[pattern]` or `{pattern}`, but only when the
        // `{`/`[` is NOT the start of a MemberExpression primary such as
        // `{}.x` or `[1][0]`. Scan ahead to distinguish the two cases.
        if ((self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET))
            && !self.primary_is_member_target()) {
            bool is_obj = self.check(TokenType.LBRACE);
            ushort synth_idx = self.add_bind(binds, {
                .key_idx = elem_idx,
                .index = elem_idx,
                .arg_idx = 0xFFFF,
                .parent_idx = parent_idx,
                .is_synthetic = true,
            })!;
            self.advance()!;  // consume '{' or '['
            if (is_obj) {
                self.collect_obj_assign_binds(binds, synth_idx)!;
            } else {
                self.collect_arr_assign_binds(binds, synth_idx)!;
            }

            // Default for the nested pattern: `[[a] = default]`
            if (self.match(TokenType.ASSIGN)) {
                uint def_idx = self.add_inner_func(self.compile_default_expr()!);
                DestructBind* sb = binds.get_ref(synth_idx);
                sb.has_default = true;
                sb.default_func_idx = def_idx;
            }
        } else {
            DestructBind b;
            self.collect_assign_target(&b)!;
            b.key_idx = elem_idx;
            b.index = elem_idx;
            b.arg_idx = 0xFFFF;
            b.parent_idx = parent_idx;
            ushort leaf_idx = self.add_bind(binds, b)!;

            // Default: `[a = expr]`, NamedEvaluation for identifier targets.
            if (self.match(TokenType.ASSIGN)) {
                char[] iname = b.is_member_target ? "" : self.bind_name(&b);
                uint def_idx = self.add_inner_func(self.compile_default_expr(iname)!);
                DestructBind* lb = binds.get_ref(leaf_idx);
                lb.has_default = true;
                lb.default_func_idx = def_idx;
            }
        }

        elem_idx++;
        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;
}

// Collect an object assignment pattern into the shared DestructBind model.
// Handles: shorthand `{a}`, `{key: target}`, computed keys `{[e]: t}`,
// member-expression targets (`{a: obj.x}`), nested array/object targets,
// defaults (`{a = d}`, `{a: t = d}`), and object rest (`{...target}`).
// The '{' has already been consumed; this consumes its own '}'.
fn void? CompilerContext.collect_obj_assign_binds(&self, DestructBinds* binds, ushort parent_idx = 0xFFFF)
{
    if (self.check(TokenType.RBRACE)) { self.advance()!; return; }

    for (;;) {
        if (self.check(TokenType.RBRACE)) break;

        // Object rest: `{...target}`, must be last.
        if (self.match(TokenType.ELLIPSIS)) {
            AssignTarget tgt = self.parse_assign_target_lhs()!;
            if (!tgt.is_member) {
                HString* hs = (HString*)self.constants[tgt.name_idx].get_heapptr();
                if (is_restricted_name(hs.get_data(),
                                       self.await_reserved_here(),
                                       self.is_generator || self.forbid_yield,
                                       strict: self.lexer.reserved_words_strict)) return COMPILE_ERROR~;
            }
            self.add_bind(binds, {
                .name_idx = tgt.name_idx,
                .key_idx = 0xFFFF,  // object-rest sentinel
                .is_object = true,
                .arg_idx = 0xFFFF,
                .parent_idx = parent_idx,
                .is_member_target = tgt.is_member,
                .member_obj_reg = tgt.obj_reg,
                .member_prop_reg = tgt.key_reg,
            })!;
            break;  // rest is the last property
        }

        // Property key: computed `[expr]`, or a literal/identifier key.
        // Per ES2022 §13.15.5.3 ObjectAssignmentPattern's computed key
        // expression evaluates AFTER the RHS (source object) is evaluated,
        // not at pattern-parse time. Defer via lexer snapshot + re-parse at
        // emission (see collect_assign_target and emit_deferred_computed_key).
        // Collection here only advances the lexer past `[expr]`, discarding
        // its code and registers. The snapshot is ours until add_bind hands
        // it to the pattern.
        bool is_computed = false;
        uint key_idx = 0xFFFFFFFF;
        TokenType key_tt = TokenType.IDENTIFIER;
        DeferredTarget* deferred_key = null;
        defer catch { if (deferred_key != null) mem::free(deferred_key); }
        if (self.check(TokenType.LBRACKET)) {
            self.advance()!; // consume '['
            DeferredTarget* snap = (DeferredTarget*)alloc::malloc_try(mem, (sz)(DeferredTarget::size)) ?? null;
            snap.lexer = *self.lexer;
            snap.pushback = self.pushback_stack;
            snap.pushback_count = self.pushback_count;
            deferred_key = snap;
            uint pre_code = self.code_count;
            ushort pre_reg = self.next_reg;
            self.assignment_expr()!;
            self.code_count = pre_code;
            self.free_regs_to(pre_reg);
            self.expect(TokenType.RBRACKET)!;
            self.expect(TokenType.COLON)!;
            is_computed = true;
        } else {
            key_tt = self.peek_type();
            char[] key = self.destructuring_property_key()!;
            key_idx = self.add_string_constant(key);
        }

        // Shorthand `{a}` / `{a = d}`: no colon → the key is also the target name.
        bool shorthand = !is_computed && !self.check(TokenType.COLON);
        if (!is_computed && !shorthand) {
            self.expect(TokenType.COLON)!;
        }

        if (shorthand) {
            // `{a}` or `{a = d}`, identifier target named by the key. The key
            // doubles as the IdentifierReference, so a reserved word that is
            // legal as a key in the `{key: target}` form is an early
            // SyntaxError here.
            if (!self.shorthand_key_is_identifier_ref(key_tt)) return COMPILE_ERROR~;
            HString* hs = (HString*)self.constants[key_idx].get_heapptr();
            if (is_restricted_name(hs.get_data(),
                                   self.await_reserved_here(),
                                   self.is_generator || self.forbid_yield,
                                   strict: self.lexer.reserved_words_strict)) return COMPILE_ERROR~;
            ushort leaf_idx = self.add_bind(binds, {
                .name_idx = key_idx,
                .key_idx = key_idx,
                .is_object = true,
                .arg_idx = 0xFFFF,
                .parent_idx = parent_idx,
            })!;
            if (self.match(TokenType.ASSIGN)) {
                // NamedEvaluation: `{a = fn}` names the anonymous fn "a".
                uint def_idx = self.add_inner_func(self.compile_default_expr(hs.get_data())!);
                DestructBind* lb = binds.get_ref(leaf_idx);
                lb.has_default = true;
                lb.default_func_idx = def_idx;
            }
        } else if ((self.check(TokenType.LBRACKET) || self.check(TokenType.LBRACE))
                   && !self.primary_is_member_target()) {
            // Nested pattern target: `key: [..]` / `key: {..}`. Emit a synthetic
            // group whose value is source[key]; delegate the sub-pattern to the
            // assign-bind collectors so member-expression leaves nested at any
            // depth (e.g. `{k: [x[yield]]}`) are accepted and deferred, not
            // just identifiers.
            bool nested_is_obj = self.check(TokenType.LBRACE);
            ushort synth_idx = self.add_bind(binds, {
                .key_idx = key_idx,
                .is_object = true,
                .is_computed_key = is_computed,
                .computed_key_reg = 0xFFFF,
                .deferred_computed_key = take_deferred(&deferred_key),
                .arg_idx = 0xFFFF,
                .parent_idx = parent_idx,
                .is_synthetic = true,
            })!;
            self.advance()!; // consume '[' or '{'
            if (nested_is_obj) {
                self.collect_obj_assign_binds(binds, synth_idx)!;
            } else {
                self.collect_arr_assign_binds(binds, synth_idx)!;
            }
            if (self.match(TokenType.ASSIGN)) {
                uint def_idx = self.add_inner_func(self.compile_default_expr()!);
                DestructBind* sb = binds.get_ref(synth_idx);
                sb.has_default = true;
                sb.default_func_idx = def_idx;
            }
        } else {
            // `key: target`, target is an identifier or member expression.
            // Member-expression targets are deferred (collect_assign_target):
            // per ES2022 §13.15.5.3 the target lref evaluates after `p` is
            // read from the source, so a side-effecting target such as
            // `{key: target()[targetKey()]}` must not run before the source
            // read (or the RHS, since collect happens before the RHS is
            // parsed at all, deferral makes it re-evaluate at emission time,
            // after both the RHS and the source property read).
            DestructBind b;
            self.collect_assign_target(&b)!;
            b.key_idx = key_idx;
            b.is_object = true;
            b.is_computed_key = is_computed;
            b.computed_key_reg = 0xFFFF;
            b.deferred_computed_key = take_deferred(&deferred_key);
            b.arg_idx = 0xFFFF;
            b.parent_idx = parent_idx;
            ushort leaf_idx = self.add_bind(binds, b)!;
            if (self.match(TokenType.ASSIGN)) {
                // NamedEvaluation for `{k: t = fn}`, only identifier targets.
                char[] iname = b.is_member_target ? "" : self.bind_name(&b);
                uint def_idx = self.add_inner_func(self.compile_default_expr(iname)!);
                DestructBind* lb = binds.get_ref(leaf_idx);
                lb.has_default = true;
                lb.default_func_idx = def_idx;
            }
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACE)!;
}

// Collect an assignment pattern starting at its '[' or '{', returning whether
// it is an object pattern. Used by destructuring assignment and by the bare
// patterns of for-in/of heads.
fn bool? CompilerContext.collect_assign_pattern(&self, DestructBinds* binds) {
    // The pattern's default values are AssignmentExpressions (ES2022
    // §13.15.5.2/§13.15.5.3), which DO permit await in async contexts and
    // yield in generator contexts, so the in_formal_params gate in
    // compile_default_expr must not apply while collecting.
    bool saved_in_fp = self.in_formal_params;
    self.in_formal_params = false;
    defer self.in_formal_params = saved_in_fp;

    bool is_object = self.peek_type() == TokenType.LBRACE;
    self.advance()!; // consume '[' or '{'
    if (is_object) {
        self.collect_obj_assign_binds(binds)!;
    } else {
        self.collect_arr_assign_binds(binds)!;
    }
    return is_object;
}

// Give each identifier leaf of an assignment pattern its binding register. A
// local reuses its own register; any other name (global, captured, or
// undeclared) gets a temp plus a forced PUTVAR, so assigning to a const
// throws. A member target gets no register here: emit_destruct_bindings
// allocates one at emission time, above the persistent object/key registers
// its pre-scan places, because the GETPROP extracting the value may run an
// accessor getter whose call frame lands at the result register and reuses
// every register above it.
fn void CompilerContext.resolve_assign_targets(&self, DestructBind[] binds) {
    foreach (&b : binds) {
        if (b.is_synthetic || b.is_member_target) continue;
        if (!self.is_global) {
            if (try existing = self.resolve_var(self.bind_name(b))) {
                b.binding_reg = existing;
                continue;
            }
        }
        b.binding_reg = self.alloc_reg();
        b.assign_needs_putvar = true;
    }
}

// Destructure `src_reg` through a collected pattern: an object pattern first
// applies RequireObjectCoercible, which rejects null/undefined even when the
// pattern is empty (§13.3.3.6), then every top-level bind reads from src_reg.
fn void CompilerContext.emit_destructure(&self, DestructBind[] binds, bool is_object, ushort src_reg,
                                         DestructStoreMode store_mode, bool is_lexical = false,
                                         bool is_const = false) {
    if (is_object) self.emit_abc(Opcode.REQUIRE_OBJ, (uint)src_reg, 0, 0);
    foreach (&b : binds) {
        if (b.parent_idx == 0xFFFF) b.arg_idx = src_reg;
    }
    self.emit_destruct_bindings(binds, store_mode, is_lexical, is_const);
}

// Parse a destructuring assignment `[a, b] = rhs` or `{a, b: c} = rhs`,
// starting at the pattern's '[' or '{'. Returns a register holding the RHS
// value, which the assignment evaluates to.
fn ushort? CompilerContext.destructure_assign(&self) {
    DestructBinds binds = { .allocator = mem };
    defer free_destruct_binds(&binds);
    bool is_object = self.collect_assign_pattern(&binds)!;
    self.resolve_assign_targets(binds.array_view());

    // Consume the '=' separating pattern from RHS (the caller verified it via
    // lookahead but did not consume it), then evaluate the RHS.
    self.expect(TokenType.ASSIGN)!;
    ushort rhs_reg = self.assignment_expr()!;

    // Assignment (not declaration): register-resident targets are written
    // directly by the extraction; env-resident targets get a bare PUTVAR;
    // member-expression targets get PUTPROP.
    self.emit_destructure(binds.array_view(), is_object, rhs_reg, DestructStoreMode.ASSIGN_TARGET);

    // Release all destructuring temporaries above the RHS register (iterator
    // state + per-element scratch), keeping rhs_reg live so the destructuring
    // assignment can evaluate to the RHS value. Prevents register drift across
    // successive destructuring statements.
    self.free_regs_to((ushort)(rhs_reg + 1));

    // Copy rhs_reg to a fresh temp so the outer assignment's free_reg(right)
    // doesn't clobber a live variable register. Without this, a pattern like
    //   result = [x = yield] = vals
    // frees vals's register (rhs_reg) after LDREG, and the subsequent
    // statement's register allocator reuses it, corrupting the variable.
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)rhs_reg, 0);
    return result_reg;
}
