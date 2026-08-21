module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;
import std::collections::list;

// ============================================================================
// Compiler-side module metadata (must match module::ModuleDef layout)
// ============================================================================

struct CompImportEntry {
    char[] local_name;
    char[] import_name;
    uint   req_module_idx;
    bool   is_star;
    bool   is_default;
}

struct CompExportEntry {
    char[] local_name;
    char[] export_name;
    bool   is_indirect;
    uint   req_module_idx;
    bool   is_lexical;      // true for a local `let`/`const`/`class` export
    // True when the export came from an `export`-PREFIXED declaration
    // (`export var x = 1`, `export function f(){}`, `export class C {}`,
    // `export var {a, b} = o`) rather than an `export { x }` clause. Such an
    // export declares its own binding in the same statement, so it trivially
    // satisfies the §16.2.1.1 ExportedBindings rule and
    // check_module_exports_resolvable skips it — the binding may be a
    // destructuring leaf that no name pre-scan reconstructs.
    bool   declares_binding;
}

struct CompStarExportEntry {
    uint req_module_idx;
}

struct CompReqModuleEntry {
    char[] module_name;
    void*  resolved;
    // True when the import specifier carried `with { type: "json" }`. The
    // referenced module is then loaded as a JSON module (parsed with
    // JSON.parse, default export = the parsed value) rather than compiled as
    // ECMAScript. Layout must match module::ReqModuleEntry.
    bool   wants_json;
    // Set at link time when the statement's bindings were all type-only (see
    // module::ReqModuleEntry.type_only). Layout must match module::ReqModuleEntry.
    bool   type_only;
}

// Full lexer + compiler-pushback snapshot, used to re-parse a source
// span (e.g. a for-of/for-in member-expression LHS) fresh on every
// loop iteration. A bare byte offset isn't enough to resume from: by
// the time the offset is captured, self.lexer.pos may already sit
// past a cached lookahead token, so the whole lexer/pushback state
// must be captured and restored together.
struct ForLhsSnapshot {
    uint pos;
    uint line;
    uint col;
    Token cur;
    Token look;
    bool haslk;
    Token push;
    bool haspb;
    bool slt;
    uint pbc;
    Token[4] pbs;
}

// --- for-of and for-await-of codegen ---
// All for-of loops share one skeleton (emit_forof); only what happens to each
// yielded value differs. ForOfHead is a tagged union describing that per-value
// step. `is_await` on emit_forof selects the sync vs async iterator protocol,
// the loop shape is otherwise identical.
enum ForOfKind {
    IDENT,        // for (x of e) / for (let x of e) / for (const x of e) / for (var x of e)
    DESTRUCTURE,  // for ([a] of e) / for ({x} of e), lexical-declared or bare-assignment
    MEMBER,       // for (obj.p of e)
}

struct ForOfHead {
    ForOfKind kind;

    // IDENT: bind the value to a single variable.
    ushort id_reg;         // loop-variable register (declared/allocated by caller)
    uint   id_name_idx;    // constant index of the variable name
    bool   id_is_bare;     // true = assign to existing lvalue, no declaration
    // Bare target that resolves to a register-cached local: id_reg is that
    // local's HOME register, so the bind writes the value straight into it (and
    // skips PUTVAR). Without this the body, which reads the local from its home
    // register, would see a stale value, since PUTVAR only updates the env slot
    // and then clears its source register (see the bare-forof var-desync fix).
    bool   id_reg_resident;

    // Shared by IDENT and DESTRUCTURE.
    bool   is_lexical;     // let/const (needs per-iteration env)
    bool   is_const;

    // DESTRUCTURE: extract the value through a pattern via emit_destruct_bindings.
    // The bind arrays are owned by the caller (stack) and pointed at val_slot
    // per iteration. store_mode is DECLARE (let/const/var decl) or ASSIGN_TARGET
    // (bare assignment pattern). is_array_pattern selects REQUIRE_OBJ vs empty-arr.
    DestructBind[] binds;
    uint           bind_count;
    ushort[]       group_regs;
    ushort[]       binding_regs;
    DestructStoreMode store_mode;
    bool           is_array_pattern;

    // MEMBER: re-parse and store into a member reference each iteration.
    ForLhsSnapshot lhs_snap;
}

// Layout must match module::FuncDeclEntry.
struct CompFuncDeclEntry {
    char[] name;
    uint   inner_func_idx;
}

// Compiler-side view of ModuleDef, field layout must match module::ModuleDef.
// The metadata lists are growable (see ModuleDef's note) and come
// pre-initialized by the module loader; the compiler only pushes into them.
struct CompModuleDef {
    char[]                                module_name;
    char                                  status;
    List{CompImportEntry}                 imports;
    List{CompExportEntry}                 exports;
    List{CompStarExportEntry}             star_exports;
    List{CompReqModuleEntry}              req_modules;
    List{CompFuncDeclEntry}               func_decls;
}

// Register a top-level module function declaration for eager link-time
// instantiation (deduplicates by name, a later declaration of the same
// name replaces the earlier inner_func_idx, mirroring last-wins hoisting).
fn void mod_register_func_decl(CompModuleDef* mod, char[] name, uint inner_func_idx) {
    for (uint i = 0; i < (uint)mod.func_decls.len(); i++) {
        if (str_eq(mod.func_decls[i].name, name)) {
            mod.func_decls[i].inner_func_idx = inner_func_idx;
            return;
        }
    }
    mod.func_decls.push({ name, inner_func_idx });
}

// Register a required module specifier, returning its index (deduplicates).
fn uint mod_register_req_module(CompModuleDef* mod, char[] specifier, bool wants_json = false) {
    for (uint i = 0; i < (uint)mod.req_modules.len(); i++) {
        // A JSON import and an ECMAScript import of the same specifier are
        // distinct module requests (different [[Attributes]]), so only reuse
        // an entry whose json-ness matches too.
        if (mod.req_modules[i].wants_json == wants_json &&
            str_eq(mod.req_modules[i].module_name, specifier)) {
            return i;
        }
    }
    uint idx = (uint)mod.req_modules.len();
    mod.req_modules.push({ specifier, null, wants_json, false });
    return idx;
}

// Register an import entry in the module.
fn void mod_register_import(CompModuleDef* mod, char[] local_name, char[] import_name, uint req_idx, bool is_star, bool is_default) {
    mod.imports.push({ local_name, import_name, req_idx, is_star, is_default });
}

// True when `export_name` is already an ExportedName of this module.
//
// ES2024 §16.2.3.1: "It is a Syntax Error if the ExportedNames of ModuleItemList
// contains any duplicate entries." Every named export funnels through
// mod_register_export, so testing here catches all the spellings that can
// collide -- `export {x}` twice, two `as z` aliases, an `export default` paired
// with `{y as default}`, two same-named `export function` declarations, and
// `export * as z` against a local `{x as z}`.
//
// `export * from` is exempt: it contributes no ExportedName of its own (a name
// it would have re-exported is instead dropped when ambiguous), which is why
// star exports are registered through mod_register_star_export and never reach
// this path.
fn bool mod_has_export_name(CompModuleDef* mod, char[] export_name) {
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        if (str_eq(mod.exports[i].export_name, export_name)) return true;
    }
    return false;
}

// Register a named export, rejecting a duplicate ExportedName (§16.2.3.1).
//
// Wraps mod_register_export at the one point every named export passes
// through, so the duplicate rule cannot be missed by a new export form:
// mod_register_export itself is a plain function with no compiler context to
// raise a SyntaxError from.
fn void? CompilerContext.register_export(&self, CompModuleDef* mod, char[] local_name,
    char[] export_name, bool is_indirect, uint req_idx, bool is_lexical = false,
    bool declares_binding = false)
{
    if (mod_has_export_name(mod, export_name)) {
        return self.fail("duplicate export name")~;
    }
    mod_register_export(mod, local_name, export_name, is_indirect, req_idx, is_lexical,
                        declares_binding);
}

// Register an export entry in the module.
fn void mod_register_export(CompModuleDef* mod, char[] local_name, char[] export_name, bool is_indirect, uint req_idx, bool is_lexical = false, bool declares_binding = false) {
    mod.exports.push({ local_name, export_name, is_indirect, req_idx, is_lexical, declares_binding });
}

// Find the ImportEntry (if any) whose local binding name is `local_name`.
// Used by `export { x }` (no `from` clause) to implement ECMA-262
// §16.2.1.7.1 ParseModule step 10.1: an export whose LocalName matches an
// already-imported binding is NOT a local export, it becomes an indirect
// re-export sourced from the ImportEntry's own module/import name, per
// Table 59. Returns null when `local_name` names an ordinary local binding.
fn CompImportEntry* mod_find_import_by_local(CompModuleDef* mod, char[] local_name) {
    for (uint i = 0; i < (uint)mod.imports.len(); i++) {
        if (str_eq(mod.imports[i].local_name, local_name)) return &mod.imports[i];
    }
    return null;
}

// Register a star export entry in the module.
fn void mod_register_star_export(CompModuleDef* mod, uint req_idx) {
    mod.star_exports.push({ req_idx });
}

// ============================================================================
// Statement parsing
// ============================================================================

// Parse and compile a single `Statement` in a position where the grammar
// admits `Statement` but not `StatementListItem`, so the body of `if` or `else`,
// a loop, or a label.
//
// Only a StatementList (a block, a function body, a case clause, the top
// level) may contain a Declaration. `if (x) let y = 1;`, `while (0) class C
// {}` and `for (;;) function f(){}` are therefore early SyntaxErrors, even
// though each body is a perfectly good StatementListItem. The engine has one
// `statement()` for both positions, so without this guard every declaration
// form was silently accepted as a bare body.
//
// `let` is only treated as a declaration here when a binding actually
// follows, so the guard reports the accurate "declaration in body position"
// error for `if (x) let y = 1;` rather than a generic parse failure. Bare
// `let` as an identifier reference (`if (x) let;`) is rejected either way,
// `statement()` routes every LET token to var_declaration(), so this engine
// does not support `let` as an IdentifierReference at all.
//
// `async function` cannot be recognised from the leading token: `async` is a
// contextual keyword that lexes as a plain IDENTIFIER, and distinguishing the
// declaration from an `async` identifier reference needs the two-token
// lookahead that statement() already performs. Rather than duplicate that
// lookahead here (doing it before statement() runs desynchronises
// `lexer.token_start`, which statement() refreshes to fix the
// Function.prototype.toString span of exactly this declaration form), the
// flag below tells statement() that it is parsing a Statement position, and
// it raises the error once it has classified the tokens.
fn void? CompilerContext.statement_body(&self) {
    switch (self.peek_type()) {
        case TokenType.CONST:
        case TokenType.CLASS:
        case TokenType.FUNCTION:
            return self.fail("declaration not allowed as a single-statement body")~;
        case TokenType.LET:
            // Distinguish the `let` declaration from the `let` identifier by
            // the token that follows it.
            if (self.peek2_starts_binding()) {
                return self.fail("declaration not allowed as a single-statement body")~;
            }
        default:
            break;
    }
    // Consumed by statement() exactly once, into a local, so it cannot leak
    // into any nested statement parsed below this one.
    self.stmt_position_only = true;
    return self.statement();
}

// Two-token lookahead for `let` in a single-statement body: true when the
// token after `let` can begin a BindingList, which is what makes the `let` a
// LexicalDeclaration rather than an identifier reference. Non-destructive:
// the consumed token is pushed back before returning.
fn bool CompilerContext.peek2_starts_binding(&self) {
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    TokenType next_tt = self.peek_type();
    self.pushback(cur);
    return next_tt == TokenType.IDENTIFIER || next_tt == TokenType.LBRACKET ||
           next_tt == TokenType.LBRACE || next_tt == TokenType.LET ||
           next_tt == TokenType.YIELD || next_tt == TokenType.AWAIT;
}

// Parse and compile a single statement, dispatching on token type.
// After the statement completes, reclaim_stmt_regs releases any temporaries
// stranded above the statement's base watermark by non-LIFO free patterns
// (see reclaim_stmt_regs).
fn void? CompilerContext.statement(&self) {
    ushort stmt_base = self.next_reg;
    TokenType tt = self.peek_type();

    // Consume the ModuleItem permission exactly once, into a local, and clear
    // the field so it cannot leak into any nested statement parsed below. Only
    // a statement dispatched directly from the module body's own loop may be
    // an Import/ExportDeclaration.
    bool at_module_top = self.module_top_level;
    self.module_top_level = false;

    // Likewise consume the Statement-position marker exactly once. See
    // statement_body(): it flags the one Declaration form its own leading-token
    // switch cannot see, `async function` / `async function*`.
    bool stmt_position_only = self.stmt_position_only;
    self.stmt_position_only = false;

    switch (tt) {
        case TokenType.LBRACE:
            self.block(false)!;
        case TokenType.VAR:
            self.var_declaration()!;
        case TokenType.LET:
            self.var_declaration()!;
        case TokenType.CONST:
            self.var_declaration()!;
        case TokenType.IF:
            self.if_statement()!;
        case TokenType.WHILE:
            self.while_statement()!;
        case TokenType.DO:
            self.do_while_statement()!;
        case TokenType.FOR:
            self.for_statement()!;
        case TokenType.RETURN:
            self.return_statement()!;
        case TokenType.THROW:
            self.throw_statement()!;
        case TokenType.TRY:
            self.try_statement()!;
        case TokenType.SWITCH:
            self.switch_statement()!;
        case TokenType.WITH:
            return self.fail("'with' statement is not supported")~;
        case TokenType.BREAK:
            self.break_statement()!;
        case TokenType.CONTINUE:
            self.continue_statement()!;
        case TokenType.FUNCTION:
            self.function_declaration()!;
        case TokenType.CLASS:
            self.class_declaration()!;
        case TokenType.IMPORT:
        {
            // `import(...)` (dynamic import) and `import.meta` (meta-property,
            // ES2024 §13.3.12) at statement level are ExpressionStatements, not
            // import declarations. Consume `import` to peek at the following
            // token, then push it back for either path.
            Token import_tok = self.advance()!;
            TokenType after_import = self.peek_type();
            bool is_expr = after_import == TokenType.LPAREN || after_import == TokenType.DOT;
            self.lexer.pushback(import_tok);
            if (is_expr) {
                self.expression_statement()!;
            } else {
                // TS: `import type ...` is fully erased, no module scope
                // required. Checked here, after the dynamic-import probe, so
                // its CompilerContext pushbacks can't desync the lexer-based
                // re-push above.
                if (self.lexer.ts_mode && self.ts_try_skip_type_only_import()!) break;
                // An ImportDeclaration is a ModuleItem, legal only in a
                // Module's top-level StatementList (ES2024 §16.2.1).
                if (!at_module_top) {
                    return self.fail("'import' declarations may only appear at the top level of a module")~;
                }
                // TS import-equals: `import Ord = O.Ord` is the legacy
                // namespace-import form. tsc strips it to `const Ord = O.Ord`,
                // so compile the same const binding.
                if (after_import == TokenType.IDENTIFIER) {
                    // Probe the token after the identifier without committing.
                    // A wrong guess rewinds the lexer position, both token
                    // slots, and the compiler pushback stack (ts-mode probes
                    // like ts_try_skip_type_only_import may have parked the
                    // import tokens there).
                    uint saved_pos = self.lexer.pos;
                    Token saved_la = self.lexer.lookahead;
                    bool saved_has_la = self.lexer.has_lookahead;
                    bool saved_has_pb = self.lexer.has_pushed_back;
                    uint saved_pbc = self.pushback_count;
                    Token[4] saved_pbs = self.pushback_stack;
                    self.advance()!;   // consume 'import'
                    Token ie_name = self.advance()!;
                    if (self.check(TokenType.ASSIGN)) {
                        self.advance()!;  // consume '='
                        self.check_lexical_redeclares_param(ie_name.str_value)!;
                        ushort reg = self.declare_var(ie_name.str_value, CONST);
                        ushort val_reg = self.assignment_expr()!;
                        if (val_reg != reg) {
                            self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                        }
                        self.free_reg(val_reg);
                        uint name_idx = self.add_string_constant(ie_name.str_value);
                        self.emit_var_store(reg, name_idx, true, true);
                        if (self.is_global) self.free_reg(reg);
                        self.match(TokenType.SEMICOLON);
                        break;
                    }
                    // Not `import NAME =`; rewind so import_declaration()
                    // re-reads the statement exactly as it was.
                    self.lexer.pos = saved_pos;
                    self.lexer.lookahead = saved_la;
                    self.lexer.has_lookahead = saved_has_la;
                    self.lexer.has_pushed_back = saved_has_pb;
                    self.pushback_count = saved_pbc;
                    self.pushback_stack = saved_pbs;
                }
                self.import_declaration()!;
            }
        }
        case TokenType.EXPORT:
            // TS: `export type ...` is fully erased, no module scope required.
            if (self.lexer.ts_mode && self.ts_try_skip_type_only_export()!) break;
            // TS: `export interface/declare/namespace ...` likewise erased.
            if (self.lexer.ts_mode && self.ts_try_skip_type_only_export_decl()!) break;
            // Likewise an ExportDeclaration is a ModuleItem: never valid
            // inside a block, loop/switch body, label or try/catch/finally.
            if (!at_module_top) {
                return self.fail("'export' declarations may only appear at the top level of a module")~;
            }
            self.export_declaration()!;
        case TokenType.SEMICOLON:
            // Empty statement
            self.advance()!;
        case TokenType.DEBUGGER:
            self.advance()!;
            self.emit_simple(Opcode.DEBUGGER);
            self.match(TokenType.SEMICOLON);
        case TokenType.INTERFACE:
            // TypeScript `interface Foo { ... }` — reject outside ts_mode.
            if (!self.lexer.ts_mode) {
                return self.fail("unexpected reserved word 'interface'")~;
            }
            self.ts_interface_declaration()!;
        case TokenType.ENUM:
            // TypeScript `enum` is not erasable — always reject.
            return self.fail("'enum' is not supported (not erasable syntax)")~;
        default:
            // TypeScript contextual keyword statements:
            //   `type X = ...;`, `declare ...`, `namespace X { ... }`, `module X {...}`
            //   `abstract class X { ... }`
            if (self.lexer.ts_mode && tt == TokenType.IDENTIFIER) {
                if (self.check_ts_ident("type")) {
                    if (self.ts_try_type_alias()) break;
                }
                if (self.check_ts_ident("declare")) {
                    if (self.ts_try_declare_statement()) break;
                }
                if (self.check_ts_ident("namespace") || self.check_ts_ident("module")) {
                    // A namespace is erasable only when its body holds just
                    // type declarations; runtime code inside is a TS1294
                    // violation and must be rejected. The keyword is a
                    // namespace head only when a name (or ambient module
                    // string) and `{` follow on the same line; CommonJS
                    // `module.exports = ...`, `namespace.foo = ...`, and
                    // ASI'd `namespace\nn { }` are ordinary identifier
                    // expressions and must fall through to the expression
                    // statement path.
                    Lexer saved_ns = *self.lexer;
                    bool ns_form = false;
                    if (catch _ne = self.advance()) {
                        *self.lexer = saved_ns;
                    } else if (self.check(TokenType.IDENTIFIER) || self.check(TokenType.STRING)) {
                        bool same_line = !self.lexer.seen_line_term;
                        if (catch _ne2 = self.advance()) {
                            *self.lexer = saved_ns;
                        } else {
                            // Dotted name: `namespace A.B { ... }`.
                            while (self.check(TokenType.DOT)) {
                                if (catch _ne3 = self.advance()) { *self.lexer = saved_ns; }
                                if (catch _ne4 = self.advance()) { *self.lexer = saved_ns; }
                            }
                            ns_form = same_line && self.check(TokenType.LBRACE);
                            *self.lexer = saved_ns;
                        }
                    } else {
                        *self.lexer = saved_ns;
                    }
                    if (ns_form) {
                        if (!self.ts_try_type_only_namespace()) {
                            return self.fail("'namespace' / 'module' is not supported (not erasable syntax)")~;
                        }
                        break;
                    }
                }
                if (self.check_ts_ident("abstract")) {
                    // `abstract class X {}` — consume `abstract` and fall through
                    // to normal class_declaration.
                    Token _abs = self.advance()!;
                    if (self.check(TokenType.CLASS)) {
                        self.class_declaration()!;
                        break;
                    }
                    // Not followed by `class`: push back and continue as identifier.
                    self.pushback(_abs);
                }
            }
            // Check for labels: identifier : statement
            // We consume the identifier and check if the next token is ':'
            //
            // A LabelIdentifier is an Identifier (§14.13), and per §13.1.1
            // `await` IS one wherever it is not reserved, so `await: ;` is a
            // valid labelled statement in script code — only the AWAIT token
            // type keeps it out of the IDENTIFIER branch here. `yield` gets no
            // such relaxation: §13.1.1 reserves it in all strict-mode code,
            // and this engine is strict-only. break/continue gate their label
            // REFERENCE on the same predicate.
            if (tt == TokenType.IDENTIFIER || self.await_is_identifier(tt)) {
                // Save token_start before consuming, in case this is an async function
                // `token_start` may be stale here (it reflects the most
                // recently *consumed* token, but the identifier we're about to
                // dispatch on is typically still a peeked lookahead). Refresh
                // it so `id_tok_start` is the identifier's real source offset,
                // required for `async function ...` declarations, whose
                // Function.prototype.toString span starts at the `async`
                // keyword. Without this, a stale offset can point past the
                // function body and underflow the retained-source span.
                self.lexer.refresh_token_start();
                uint id_tok_start = self.lexer.token_start;
                // Consume the identifier token to check what follows. The
                // guard above admits only IDENTIFIER and an `await` that this
                // context already treats as an identifier, and both a
                // LabelIdentifier and an IdentifierReference are Identifier
                // grammar, so an escaped spelling is a plain name here.
                Token id_tok = self.advance(true)!;
                if (self.peek_type() == TokenType.COLON) {
                    // A LabelIdentifier is an Identifier (§14.13), so a
                    // ReservedWord may not be one. `true`/`false`/`null` lex
                    // as IDENTIFIER here (they are matched by name in
                    // primary_expr rather than living in the keyword table),
                    // so they have to be excluded explicitly, escaped or not.
                    // `eval`/`arguments` are NOT reserved and remain valid
                    // label names.
                    if (str_eq(id_tok.str_value, "true")
                            || str_eq(id_tok.str_value, "false")
                            || str_eq(id_tok.str_value, "null")) {
                        return self.fail("reserved word cannot be used as a label")~;
                    }
                    self.advance()!; // consume ':'
                    self.labeled_statement(id_tok.str_value)!;
                    break;
                }

                // `async function name() {}`, treat as function declaration,
                // but only when `async` IS the contextual keyword and there
                // is no LineTerminator between `async` and `function`
                // (ES2017 §14.7). Escaped `\u0061sync` is a plain identifier
                // (ES2024 §5.1.5), not the contextual keyword, and a line
                // terminator restores the default reading: `async` is an
                // IdentifierReference expression statement, and the
                // following `function …` is a separate FunctionDeclaration.
                if (id_tok.str_value.len == 5 &&
                    id_tok.str_value[0] == 'a' && id_tok.str_value[1] == 's' &&
                    id_tok.str_value[2] == 'y' && id_tok.str_value[3] == 'n' &&
                    id_tok.str_value[4] == 'c' &&
                    !id_tok.has_escape) {
                    Token next_tok;
                    if (self.pushback_count > 0) {
                        next_tok = self.pushback_stack[self.pushback_count - 1];
                    } else {
                        Token? peek_opt = self.lexer.peek();
                        if (catch _e = peek_opt) {
                            return self.fail("expected statement, got end of input")~;
                        }
                        next_tok = peek_opt;
                    }
                    if (next_tok.type == TokenType.FUNCTION && next_tok.line == id_tok.line) {
                        // An AsyncFunctionDeclaration / AsyncGeneratorDeclaration
                        // is a Declaration, so it is not a Statement and cannot
                        // be an if/else arm, a loop body or a labelled
                        // statement (§14.4-§14.7, §14.13). Only reachable once
                        // the tokens above have confirmed the contextual
                        // keyword, which is why statement_body() defers to here.
                        if (stmt_position_only) {
                            return self.fail("declaration not allowed as a single-statement body")~;
                        }
                        // id_tok was `async`; next token is `function` on
                        // the same line. Consume was the `async`; the next
                        // advance() in function_declaration returns `function`.
                        self.function_declaration(true, id_tok_start)!;
                        break;
                    }
                }

                // `using` is a reserved declaration introducer in current
                // ECMAScript grammar. Explicit resource management is not
                // implemented, so reject it instead of parsing it as an
                // identifier expression that ASI may split across lines.
                if (id_tok.str_value.len == 5
                    && id_tok.str_value[0] == 'u' && id_tok.str_value[1] == 's'
                    && id_tok.str_value[2] == 'i' && id_tok.str_value[3] == 'n'
                    && id_tok.str_value[4] == 'g') {
                    return self.fail("using declarations are not supported")~;
                }

                // Not a label or async function, push the identifier back and fall through
                self.lexer.pushback(id_tok);
            }
            self.expression_statement()!;
    }

    self.reclaim_stmt_regs(stmt_base);
}

// Check if a name is restricted in strict mode (ES5 §11.6.2.2, ES2024 §13.3.1).
// The engine is strict-only, there is no non-strict context in which these
// may appear in a binding position, so we always reject:
//   - `eval`, `arguments`, ES5 strict-only identifiers (§11.6.2.2).
//   - `null`, `true`, `false`, NullLiteral / BooleanLiteral sources; never
//     valid as an IdentifierName in binding position. Lexed as IDENTIFIER
//     with `str_value` matching the literal name (no dedicated token type
//     in this engine), so a post-advance check is the only way to catch
//     `var true = 1` while still allowing property access `obj.true` etc.
//   - `yield`, `await`, `let`, `static`, `implements`, `interface`, `package`,
//     `private`, `protected`, `public`, strict-mode reserved words. Most
//     already come through this path via the lexer's KEYWORDS table
//     (which would deliver a keyword token instead of IDENTIFIER), but
//     `yield` and `await` slip through in non-generator / non-module
//     contexts where the lexer still returns the keyword token, and
//     var_declaration deliberately accepts them. The strict-only engine
//     must always reject.
fn bool is_restricted_name(char[] name,
                           bool in_async_or_module = true,
                           bool in_generator_or_blocked_yield = true) @inline {
    switch (name.len) {
        case 3:
            // "let"
            if (name[0] == 'l' && name[1] == 'e' && name[2] == 't') return true;
            break;
        case 4:
            // "eval", "null", "true"
            if (name[0] == 'e' && name[1] == 'v' && name[2] == 'a' && name[3] == 'l') return true;
            if (name[0] == 'n' && name[1] == 'u' && name[2] == 'l' && name[3] == 'l') return true;
            if (name[0] == 't' && name[1] == 'r' && name[2] == 'u' && name[3] == 'e') return true;
            break;
        case 5:
            // "await", "false", "yield"
            // await is reserved only inside an async function/arrow/method, a
            // module, or a class static block ([Await] grammar parameter);
            // outside those scopes it is a plain IdentifierName and may appear
            // as an assignment target. Same shape for yield, with [Yield]
            // scoping. Pass false from callers that know the context is
            // outside the reservation scope (assignment LHS, destructuring).
            if (name[0] == 'a' && name[1] == 'w' && name[2] == 'a' &&
                name[3] == 'i' && name[4] == 't') return in_async_or_module;
            if (name[0] == 'f' && name[1] == 'a' && name[2] == 'l' &&
                name[3] == 's' && name[4] == 'e') return true;
            if (name[0] == 'y' && name[1] == 'i' && name[2] == 'e' &&
                name[3] == 'l' && name[4] == 'd') return in_generator_or_blocked_yield;
            break;
        case 6:
            // "static"
            if (name[0] == 's' && name[1] == 't' && name[2] == 'a' &&
                name[3] == 't' && name[4] == 'i' && name[5] == 'c') return true;
            break;
        case 7:
            // "package", "private", "public"
            if (name[0] == 'p' && name[1] == 'a' && name[2] == 'c' &&
                name[3] == 'k' && name[4] == 'a' && name[5] == 'g' &&
                name[6] == 'e') return true;
            if (name[0] == 'p' && name[1] == 'r' && name[2] == 'i' &&
                name[3] == 'v' && name[4] == 'a' && name[5] == 't' &&
                name[6] == 'e') return true;
            if (name[0] == 'p' && name[1] == 'u' && name[2] == 'b' &&
                name[3] == 'l' && name[4] == 'i' && name[5] == 'c') return true;
            break;
        case 9:
            // "arguments", "interface"
            if (name[0] == 'a' && name[1] == 'r' && name[2] == 'g' &&
                name[3] == 'u' && name[4] == 'm' && name[5] == 'e' &&
                name[6] == 'n' && name[7] == 't' && name[8] == 's') return true;
            if (name[0] == 'i' && name[1] == 'n' && name[2] == 't' &&
                name[3] == 'e' && name[4] == 'r' && name[5] == 'f' &&
                name[6] == 'a' && name[7] == 'c' && name[8] == 'e') return true;
            break;
        case 10:
            // "implements"
            if (name[0] == 'i' && name[1] == 'm' && name[2] == 'p' &&
                name[3] == 'l' && name[4] == 'e' && name[5] == 'm' &&
                name[6] == 'e' && name[7] == 'n' && name[8] == 't' &&
                name[9] == 's') return true;
            break;
    }
    // "protected"
    if (name.len == 9 && name[0] == 'p' && name[1] == 'r' && name[2] == 'o' &&
        name[3] == 't' && name[4] == 'e' && name[5] == 'c' && name[6] == 't' &&
        name[7] == 'e' && name[8] == 'd') {
        return true;
    }
    return false;
}

// IsSimpleParameterList (ES2024 §15.1.3) for the FormalParameters of the
// function currently being compiled.
//
// A list is simple only when every parameter is a plain BindingIdentifier: a
// rest element, any initializer (`=`), or a destructuring pattern makes it
// non-simple. Each of the three parameter-parsing loops (function, method,
// arrow) records those three signals on the context, so this reads them
// rather than re-deriving the answer per call site.
//
// Trivially true outside a function body — a program, eval or module has no
// formals and leaves all three signals at their zero values.
fn bool CompilerContext.params_are_simple(&self) {
    return !self.has_rest
        && self.default_count == 0
        && self.destruct_default_count == 0
        && !self.has_destructured_param;
}

// Parse directive prologue statements at the start of a function body or program.
// Detects "use strict" and enables strict mode if found (ES5 §14.1).
fn void? CompilerContext.parse_directives(&self) {
    while (true) {
        if (!self.check(TokenType.STRING)) {
            break;
        }

        Token str_tok = self.advance()!;

        // A directive's string is never evaluated as an expression, so it
        // never reaches primary_expr's octal check. The early error still
        // applies (ES2024 §12.9.4.1: a LegacyOctalEscapeSequence is a Syntax
        // Error in strict code, and a DirectivePrologue member is strict code
        // here because the engine is strict-only), so check it directly.
        if (str_tok.has_octal_escape) {
            return self.fail("octal escape sequences are not allowed in strict mode")~;
        }

        bool has_semicolon = self.check(TokenType.SEMICOLON);
        // ASI ends the ExpressionStatement at a line terminator, and also at
        // the `}` that closes the enclosing body — so a body whose last
        // statement is the directive (`function f(a=1) { "use strict" }`, no
        // trailing semicolon) still has a directive prologue.
        bool has_asi = self.lexer.seen_line_term || self.check(TokenType.RBRACE);

        if (has_semicolon || has_asi) {
            if (has_semicolon) {
                self.advance()!;
            }

            if (str_tok.str_value.len == 10) {
                bool is_use_strict = true;
                char[] expected = "use strict";
                for (usz i = 0; i < 10; i++) {
                    if (str_tok.str_value[i] != expected[i]) {
                        is_use_strict = false;
                        break;
                    }
                }
                if (is_use_strict) {
                    // ES2024 §15.2.1 / §15.3.1 / §15.4.1 / §15.5.1 / §15.6.1
                    // / §15.7.1 / §15.8.1: "It is a Syntax Error if
                    // ContainsUseStrict of FunctionBody is true and
                    // IsSimpleParameterList of FormalParameters is false."
                    // The engine is strict-only, so the directive itself is a
                    // no-op — but the early error still has to fire, because
                    // the parameter initialisers of a non-simple list would
                    // otherwise be evaluated in a scope whose strictness the
                    // directive claims to change.
                    //
                    // Only a FUNCTION body can hit this: at program, eval and
                    // module level there are no formals, so params_are_simple
                    // is trivially true.
                    if (!self.params_are_simple()) {
                        return self.fail("Illegal 'use strict' directive in function with non-simple parameter list")~;
                    }
                    // Code is already strict; the directive is a no-op except
                    // that it makes a dynamic Function body an ordinary strict
                    // function, whose undefined receiver stays undefined.
                    self.saw_use_strict = true;
                    self.subst_global_this = false;
                    if (self.current_func != null) {
                        self.current_func.flags.subst_global_this = false;
                    }
                }
            }
        } else {
            self.lexer.pushback(str_tok);
            break;
        }
    }
}

// Pre-scan tokens in the current block to find all `let`/`const` variable
// declarations at the top level of the block (brace depth 0, excluding nested
// blocks).  Saves and restores the lexer state so normal parsing can proceed
// afterwards.
//
// Returns the number of variable names found (0 to MAX_PRESCAN_NAMES).
// Record a prescanned binding name into `spans[idx]`. A plain identifier's
// str_value points into the source buffer, so it is stored as a (pos, len)
// span reconstructed later from `lexer.source`. An identifier that contained
// a unicode escape (`\uXXXX`) is decoded by the lexer into a reused scratch
// buffer whose contents don't survive the next token, so its bytes are
// interned to stable storage and kept directly in the span instead.
fn void CompilerContext.record_name_span(&self, NameSpan* span, Token name_tok, char* source_base) {
    char* end = &self.lexer.source[self.lexer.source.len - 1];
    if (name_tok.str_value.ptr >= source_base && name_tok.str_value.ptr <= end) {
        span.pos = (uint)((usz)name_tok.str_value.ptr - (usz)source_base);
        span.len = (uint)name_tok.str_value.len;
        span.name = {};
    } else {
        span.pos = 0;
        span.len = 0;
        span.name = self.intern_slot_name(name_tok.str_value);
    }
    // Only pre_scan_switch_lexical_decls sets these, and only for a
    // FunctionDeclaration (see NameSpan.is_fn); every other caller collects
    // let/const/class names, which stay TDZ-initialized at block entry.
    span.is_fn = false;
}

// Reconstruct a prescanned binding name from a NameSpan, either its
// interned decoded bytes (escaped identifiers) or a slice of the source.
fn char[] CompilerContext.name_span_text(&self, NameSpan span) {
    if (span.name.len > 0) return span.name;
    return self.lexer.source[span.pos..span.pos + span.len - 1];
}

// True when a `class` following `prev_tt` is a ClassDeclaration (statement
// position, its BindingIdentifier is a block-scoped lexical binding),
// rather than a ClassExpression (`x = class C {}`, `f(class C {})`, etc.,
// where `C` binds only inside the class body). A declaration only begins a
// Statement, so the token before it is a statement boundary; an expression
// `class` follows an operator, `=`, `(`, `,`, `return`, `[`, `:`, etc.
fn bool class_is_declaration(TokenType prev_tt) {
    switch (prev_tt) {
        case TokenType.SEMICOLON:
        case TokenType.LBRACE:
        case TokenType.RBRACE:
            return true;
        default:
            return false;
    }
}

// TDZ-initialize top-level let/const declarations at program/eval scope so
// that accessing or assigning to them before their declaration throws a
// ReferenceError, matching block scope. Mirrors the INITTZ pass in block().
fn void CompilerContext.hoist_lexical_tdz(&self) {
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    for (uint i = 0; i < n; i++) {
        char[] name = self.name_span_text(spans[i]);
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
    }
}

// Reject a module-scope lexical binding named `name` that already exists, for
// the one declaration form check_module_duplicate_lexical_names cannot
// pre-scan: `export default function F(){}`, whose `F` is not in statement
// position and so is never recorded by hoist_global_fn_decls. By the time the
// declaration is parsed, any colliding `class`/`let`/`const` is already on
// scope_stack.
fn void? CompilerContext.check_module_lexical_collision(&self, char[] name) {
    if (!self.is_module) return;
    for (uint i = 0; i < self.scope_depth; i++) {
        ScopeEntry* e = &self.scope_stack[i];
        if ((e.kind == LET || e.kind == CONST) && str_eq(e.name, name)) {
            return self.fail("Identifier has already been declared")~;
        }
    }
}

// ES2024 §16.2.1.1: a MODULE body's LexicallyDeclaredNames must contain no
// duplicates. Unlike a Script's, a module's top-level FunctionDeclarations are
// lexical, so `class F {} function F(){}` is a SyntaxError where the same pair
// is legal at Script top level (there the function is var-scoped and simply
// wins).
//
// Runs over the two name sets the module prologue has already collected: the
// let/const/class spans from pre_scan_lexical_decls, and the function names
// hoist_global_fn_decls recorded in hoisted_fn_names. Function-vs-function
// duplicates are already rejected inside that pre-scan, so this adds the
// lex-vs-lex and lex-vs-function pairings.
fn void? CompilerContext.check_module_duplicate_lexical_names(&self) {
    if (!self.is_module) return;
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    self.check_duplicate_lexical_names(&spans[0], n)!;
    for (uint i = 0; i < n; i++) {
        char[] name = self.name_span_text(spans[i]);
        for (ushort h = 0; h < self.hoisted_fn_count; h++) {
            if (str_eq(self.hoisted_fn_names[h], name)) {
                return self.fail("Identifier has already been declared")~;
            }
        }
    }
}

// §16.2.1.1: "It is a Syntax Error if any element of the ExportedBindings of
// ModuleItemList does not also occur in either the VarDeclaredNames of
// ModuleItemList, or the LexicallyDeclaredNames of ModuleItemList."
//
// So `export { unresolvable };` is a SyntaxError, and so is
// `export { Number };` — a global is not a module-level declaration. Only a
// LOCAL export has an ExportedBinding: `export { x } from './m'` names `x`
// in the OTHER module, and a star export names nothing here.
//
// Runs after the whole body is parsed, because the rule is about the module
// item LIST: `export { later }; var later = 1;` is legal, the declaration
// need not precede the export. The four sources of a module-level declared
// name at that point are:
//   - top-level `let`/`const`/`class`, still on scope_stack (the caller runs
//     this before pop_scope_to(0));
//   - top-level `function`, in hoisted_fn_names, or in the module's
//     func_decls when the declaration carried its own `export` prefix
//     (`export function g(){}`), which the hoisting pre-scan does not see;
//   - top-level `var`, which at module scope is never pushed to scope_stack
//     (declare_var's is_global path), hence the pre-scan;
//   - imported bindings, which are LexicallyDeclaredNames of the module.
// The pre-scan rewinds and restores the lexer itself, so calling it here,
// with the lexer parked at EOF, is safe.
fn void? CompilerContext.check_module_exports_resolvable(&self) {
    if (!self.is_module || self.current_module == null) return;
    CompModuleDef* mod = self.get_module_def();

    NameSpan[MAX_PRESCAN_NAMES] var_spans;
    uint var_n = 0;
    // Only pay for the pre-scan if some local export could actually need it.
    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        if (!mod.exports[i].is_indirect) {
            uint saved_pos = self.lexer.pos;
            self.lexer.pos = 0;
            self.lexer.has_lookahead = false;
            self.lexer.has_pushed_back = false;
            var_n = self.pre_scan_var_decls(&var_spans, MAX_PRESCAN_NAMES);
            self.lexer.pos = saved_pos;
            break;
        }
    }

    for (uint i = 0; i < (uint)mod.exports.len(); i++) {
        if (mod.exports[i].is_indirect) continue;
        // An `export`-prefixed declaration binds its own name in the same
        // statement, so it always satisfies the rule. Skipping it also avoids
        // having to reconstruct the leaf names of `export var {a, b} = o`,
        // which no name pre-scan recovers.
        if (mod.exports[i].declares_binding) continue;
        char[] local = mod.exports[i].local_name;

        bool found = false;
        for (uint s = 0; s < self.scope_depth && !found; s++) {
            if (str_eq(self.scope_stack[s].name, local)) found = true;
        }
        for (ushort h = 0; h < self.hoisted_fn_count && !found; h++) {
            if (str_eq(self.hoisted_fn_names[h], local)) found = true;
        }
        for (uint d = 0; d < (uint)mod.func_decls.len() && !found; d++) {
            if (str_eq(mod.func_decls[d].name, local)) found = true;
        }
        for (uint v = 0; v < var_n && !found; v++) {
            if (str_eq(self.name_span_text(var_spans[v]), local)) found = true;
        }
        for (uint m = 0; m < (uint)mod.imports.len() && !found; m++) {
            if (str_eq(mod.imports[m].local_name, local)) found = true;
        }
        if (!found) {
            return self.fail("export names a binding that is not declared in this module")~;
        }
    }
}

// Emit the GlobalDeclarationInstantiation lexName collision checks
// (ES2015 §15.1.11 step 5) for the top-level `let`/`const`/`class` names.
// Part of the check prologue that must precede every binding instantiation,
// so a SyntaxError (existing var/lex binding or restricted global property)
// throws with no observable side effects. Module top-level lexicals live in
// the Module Environment Record, which has no such restriction, so this is
// Script/eval only.
fn void? CompilerContext.hoist_lexical_tdz_checks(&self) {
    if (self.is_module) return;
    self.check_script_duplicate_lexical_names()!;
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    for (uint i = 0; i < n; i++) {
        char[] name = self.name_span_text(spans[i]);
        uint chk_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.CHKGLOBALLEX, 0, chk_idx);
    }
}

// Each name's position in the source text is stored in `spans` so the
// caller can reconstruct the `char[]` slice from `lexer.source`.
fn uint CompilerContext.pre_scan_lexical_decls(&self, NameSpan* spans, uint capacity) {
    // An empty source has nothing to scan, and `&source[0]` would fault on it.
    if (self.lexer.source.len == 0) return 0;
    // --- Save lexer state ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    char* source_base = &self.lexer.source[0];

    uint     count       = 0;
    uint     brace_depth = 0;
    // Paren nesting at the block's top level. A let/const keyword inside
    // top-level parens can only be a for-head LexicalDeclaration (valid code
    // has no other parenthesised let/const), and for-head names bind in the
    // for statement's own declarative environment (ES2024 §14.7.4/§14.7.5),
    // NOT in this block, collecting them here TDZ-initialises a bogus
    // block-scope binding and falsely triggers the lex-vs-var early error
    // for `function f() { var x; for (let x in {}) {} }`. The for-head vs
    // body-var early error (§13.7.4.1/§13.7.5.13) is enforced at parse time
    // by check_var_lex_conflict.
    uint     paren_depth = 0;
    // Previous significant token, used to tell a class DECLARATION from a
    // class EXPRESSION (see class_is_declaration). Branches that consume
    // extra tokens and `continue` reset this to a statement boundary, since
    // a let/const/class declaration is always statement-terminated.
    TokenType prev_tt = TokenType.SEMICOLON;

    while (count < capacity) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) {
            break;
        }
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) {
            break;
        }

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            prev_tt = tt;
            continue;
        }

        if (tt == TokenType.RBRACE) {
            if (brace_depth == 0) {
                break;   // end of the block we are scanning
            }
            brace_depth--;
            prev_tt = tt;
            continue;
        }

        if (tt == TokenType.LPAREN) {
            paren_depth++;
            prev_tt = tt;
            continue;
        }

        if (tt == TokenType.RPAREN) {
            if (paren_depth > 0) {
                paren_depth--;
            }
            prev_tt = tt;
            continue;
        }

        // Only collect let/const at the top level of this block (depth 0),
        // excluding for-head parens (see paren_depth above).
        if (brace_depth == 0 && paren_depth == 0 && (tt == TokenType.LET || tt == TokenType.CONST)) {
            // Collect one or more identifier names (comma-separated). The
            // token that ends the list decides what follows: a `;` (or a
            // pattern this loop cannot read) leaves us at a statement
            // boundary, while an `=` leaves us inside an initialiser, where
            // a following `class` is an EXPRESSION whose name binds nothing
            // (`let A = class A {}` declares one `A`, not two).
            uint list_start_count = count;
            TokenType list_end = TokenType.SEMICOLON;
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) {
                    break;
                }
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) {
                    list_end = name_tok.type;
                    break;
                }
                // Store the name's position in the source text.
                if (count < capacity) {
                    self.record_name_span(&spans[count], name_tok, source_base);
                    count++;
                }
                // Check for comma (multiple declarations).
                Token? sep_opt = self.lexer.next_token();
                if (catch _err3 = sep_opt) {
                    break;
                }
                Token sep = sep_opt;
                if (sep.type != TokenType.COMMA) {
                    list_end = sep.type;
                    break;
                }
                // continue to the next declarator name
            }
            // A `const`/`let` inside a TypeScript generic parameter list
            // (`declare function f<const T>(...)`) is a type-parameter
            // modifier, not a declaration: its list ends with `>` rather
            // than a declaration terminator, so drop the names collected
            // for it (they would otherwise collide across two `<const T>`
            // lists and trip the duplicate-lexical-names check).
            if (list_end != TokenType.SEMICOLON && list_end != TokenType.ASSIGN
                && list_end != TokenType.COLON && list_end != TokenType.COMMA) {
                count = list_start_count;
            }
            prev_tt = list_end;
            continue;
        }

        // class Name { ... }, collect the binding name. Class declarations
        // are lexically scoped exactly like let/const (ES2015 §14.5.15
        // BlockDeclarationInstantiation), so a `typeof C` before `class C {}`
        // must observe the TDZ, not fall through to "undefined". A class
        // EXPRESSION's name (`var A = class B {}`) is NOT such a binding and
        // must not be collected, distinguished by statement position.
        if (brace_depth == 0 && tt == TokenType.CLASS && class_is_declaration(prev_tt)) {
            Token? name_opt = self.lexer.next_token();
            if (catch _err4 = name_opt) {
                break;
            }
            Token name_tok = name_opt;
            if (name_tok.type == TokenType.IDENTIFIER && count < capacity) {
                self.record_name_span(&spans[count], name_tok, source_base);
                count++;
            }
            prev_tt = tt;
            continue;
        }

        prev_tt = tt;
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

    return count;
}

// Pre-scan tokens in the current block body to find all `var` declarators
// at any brace_depth (excluding nested function/class bodies, which are
// separate VarDeclaredNames scopes per ES2024 §13.2.13 / §14.5 / §13.15.1).
// Together with pre_scan_lexical_decls this feeds the
// BlockDeclarationInstantiation conflict check in block()
// (ES2024 §13.2.1 / §15.7.11: a name cannot be both LexicallyDeclaredNames
// and VarDeclaredNames). VarDeclaredNames recursively descends into nested
// BlockStatements per §13.2.5, so var names at any brace_depth inside the
// block contribute. Saves/restores lexer state so normal parsing can
// proceed afterwards.
fn uint CompilerContext.pre_scan_var_decls(&self, NameSpan* spans, uint capacity) {
    // An empty source has nothing to scan, and `&source[0]` would fault on it.
    if (self.lexer.source.len == 0) return 0;
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    char* source_base = &self.lexer.source[0];

    uint count           = 0;
    uint brace_depth     = 0;

    while (count < capacity) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) break;
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) break;

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }
        if (tt == TokenType.RBRACE) {
            if (brace_depth == 0) break;
            brace_depth--;
            continue;
        }

        // function / function* / async function / class, consume the whole
        // nested body inline: its `var` names belong to that nested scope's
        // VarDeclaredNames, not this block's. The inner walk swallows every
        // token through the body's closing RBRACE, so the outer loop resumes
        // cleanly at the next statement with brace_depth untouched.
        //
        // `class` only when it really opens one: as a PropertyName or member
        // name it is an ordinary IdentifierName (`{ class: 1 }`, `o.class`),
        // and consuming a body for it eats the enclosing block's tokens (see
        // class_kw_starts_class).
        if (tt == TokenType.FUNCTION
            || (tt == TokenType.CLASS && self.class_kw_starts_class())) {
            int depth = 0;
            bool seen_body = false;
            while (true) {
                Token? t_opt = self.lexer.next_token();
                if (catch _e = t_opt) break;
                Token t = t_opt;
                if (t.type == TokenType.EOF_TOKEN) break;
                if (t.type == TokenType.LBRACE) {
                    depth++;
                    seen_body = true;
                } else if (t.type == TokenType.RBRACE) {
                    depth--;
                    if (seen_body && depth == 0) break;
                }
            }
            continue;
        }

        // Arrow with a block body: `=> { ... }` is its own VarDeclaredNames
        // scope too. Expression-bodied arrows have no braces of their own,
        // and object literals after `=>` can't contain `var`, so only the
        // LBRACE-immediately-after-ARROW shape needs consuming.
        if (tt == TokenType.ARROW) {
            Token? body_opt = self.lexer.next_token();
            if (catch _e = body_opt) break;
            Token body_tok = body_opt;
            if (body_tok.type != TokenType.LBRACE) {
                self.lexer.pushback(body_tok);
                continue;
            }
            int depth = 1;
            while (depth > 0) {
                Token? t_opt = self.lexer.next_token();
                if (catch _e2 = t_opt) break;
                Token t = t_opt;
                if (t.type == TokenType.EOF_TOKEN) break;
                if (t.type == TokenType.LBRACE) {
                    depth++;
                } else if (t.type == TokenType.RBRACE) {
                    depth--;
                }
            }
            continue;
        }

        // Collect var declarators anywhere inside this block; nested
        // function/class bodies were consumed above.
        if (tt == TokenType.VAR) {
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) break;
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) break;
                if (count < capacity) {
                    self.record_name_span(&spans[count], name_tok, source_base);
                    count++;
                }
                Token? sep_opt = self.lexer.next_token();
                if (catch _err3 = sep_opt) break;
                Token sep = sep_opt;
                if (sep.type == TokenType.COMMA) continue;
                // An Initializer separates this declarator from the next, so
                // skip it to reach the comma: without this the scan stopped at
                // the first `=` and `var a = 1, b = 2` reported only `a`.
                // Track nesting so a `,` inside the initializer's own parens,
                // brackets or braces (`var a = f(1, 2), b`) is not mistaken
                // for the declarator separator.
                if (sep.type != TokenType.ASSIGN) break;
                int init_depth = 0;
                bool at_next_declarator = false;
                for (;;) {
                    Token? it_opt = self.lexer.next_token();
                    if (catch _err4 = it_opt) break;
                    Token it = it_opt;
                    if (it.type == TokenType.EOF_TOKEN) break;
                    if (it.type == TokenType.LPAREN || it.type == TokenType.LBRACKET ||
                        it.type == TokenType.LBRACE) {
                        init_depth++;
                    } else if (it.type == TokenType.RPAREN || it.type == TokenType.RBRACKET ||
                               it.type == TokenType.RBRACE) {
                        // A closer at depth 0 ends the enclosing construct
                        // (`{ var a = 1 }`), not the initializer list. Push it
                        // back so the outer loop's brace bookkeeping sees it.
                        if (init_depth == 0) { self.lexer.pushback(it); break; }
                        init_depth--;
                    } else if (init_depth == 0) {
                        if (it.type == TokenType.COMMA) { at_next_declarator = true; break; }
                        if (it.type == TokenType.SEMICOLON) break;
                    }
                }
                if (!at_next_declarator) break;
            }
            continue;
        }
    }

    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;

    return count;
}

// Pre-scan tokens in the current switch CaseBlock to find all lexically
// scoped declarations directly inside case/default clauses: `let`/`const`
// bindings, `class` declarations, and (non-strict-hoisted) `function`/
// `function*`/`async function` declarations at the top level of the
// CaseBlock (brace depth 0, excluding nested blocks).
//
// ES2015 §14.12 CaseBlock has its own lexical scope (BlockDeclarationInstantiation),
// so all of these names must be TDZ-initialized/scoped to the switch, exactly
// like block()'s treatment of let/const, this just widens the name set to
// match everything CaseBlockEvaluation's BlockDeclarationInstantiation collects.
//
// Saves and restores the lexer state so normal parsing can proceed afterwards.
// Returns the number of names found (0 to MAX_PRESCAN_NAMES).
fn uint CompilerContext.pre_scan_switch_lexical_decls(&self, NameSpan* spans, uint capacity) {
    // An empty source has nothing to scan, and `&source[0]` would fault on it.
    if (self.lexer.source.len == 0) return 0;
    // --- Save lexer state ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    char* source_base = &self.lexer.source[0];

    uint     count       = 0;
    uint     brace_depth = 0;
    // See pre_scan_lexical_decls: tells a class DECLARATION from an
    // expression so `case 0: var A = class B {}` doesn't leak `B`.
    TokenType prev_tt = TokenType.SEMICOLON;
    // A `case`/`default` label ends at its `:`, which opens statement
    // position, a FunctionDeclaration or `class` there is a lexical
    // CaseBlock binding. Distinguish that label colon from a ternary
    // `?:` colon by tracking whether an unmatched `?` is still open, and
    // from a colon nested in parens/brackets via paren_depth.
    uint     paren_depth = 0;
    uint     question_depth = 0;

    while (count < capacity) {
        // Snapshot before consuming, so a FunctionDeclaration found below can
        // record the position of its `function` / `async` keyword for
        // block()/switch_statement() to re-parse from (NameSpan.fn_pos).
        LexerPos pos_before = self.capture_lexer_pos();
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) {
            break;
        }
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) {
            break;
        }

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            prev_tt = tt;
            continue;
        }

        if (tt == TokenType.RBRACE) {
            if (brace_depth == 0) {
                break;   // end of the CaseBlock we are scanning
            }
            brace_depth--;
            prev_tt = tt;
            continue;
        }

        if (brace_depth != 0) {
            prev_tt = tt;
            continue;
        }

        // Track paren/bracket nesting and open ternary `?` so that only a
        // top-level case/default label colon (not a ternary or subscript
        // colon) is treated as a statement-position boundary below.
        if (tt == TokenType.LPAREN || tt == TokenType.LBRACKET) {
            paren_depth++;
            prev_tt = tt;
            continue;
        }
        if (tt == TokenType.RPAREN || tt == TokenType.RBRACKET) {
            if (paren_depth > 0) paren_depth--;
            prev_tt = tt;
            continue;
        }
        if (tt == TokenType.QUESTION && paren_depth == 0) {
            question_depth++;
            prev_tt = tt;
            continue;
        }
        if (tt == TokenType.COLON && paren_depth == 0) {
            if (question_depth > 0) {
                // Closes a ternary, not a case label.
                question_depth--;
                prev_tt = tt;
            } else {
                // A `case <expr>:` / `default:` label colon: the following
                // declaration is at statement position.
                prev_tt = TokenType.SEMICOLON;
            }
            continue;
        }

        // let/const: collect one or more comma-separated identifier names.
        // Excludes for-head parens (a let/const at paren_depth > 0 is a
        // for-head LexicalDeclaration, scoped to the for statement, see
        // pre_scan_lexical_decls).
        if (paren_depth == 0 && (tt == TokenType.LET || tt == TokenType.CONST)) {
            // Token that ended the declarator list, used as prev_tt when the
            // main loop resumes. Defaults to SEMICOLON so a list that runs to
            // a parse error still leaves the scanner at statement position.
            TokenType last_sep_tt = TokenType.SEMICOLON;
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) {
                    break;
                }
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) {
                    break;
                }
                if (count < capacity) {
                    self.record_name_span(&spans[count], name_tok, source_base);
                    count++;
                }
                Token? sep_opt = self.lexer.next_token();
                if (catch _err3 = sep_opt) {
                    break;
                }
                Token sep = sep_opt;
                if (sep.type != TokenType.COMMA) {
                    // The declarator has an initializer (`=`) or the statement
                    // ended. Carry the separator out as prev_tt: resuming with
                    // a hard-coded SEMICOLON would put the initializer at
                    // statement position, so `let x = class x {}` /
                    // `let y = function y() {}` would take the class/function
                    // DECLARATION branch below and collect the expression's own
                    // name as a second block-level binding — a spurious
                    // duplicate against the `let` name just recorded.
                    last_sep_tt = sep.type;
                    break;
                }
            }
            prev_tt = last_sep_tt;
            continue;
        }

        // class Name { ... }, collect the binding name (declaration only).
        if (tt == TokenType.CLASS && class_is_declaration(prev_tt)) {
            Token? name_opt = self.lexer.next_token();
            if (catch _err4 = name_opt) {
                break;
            }
            Token name_tok = name_opt;
            if (name_tok.type == TokenType.IDENTIFIER && count < capacity) {
                self.record_name_span(&spans[count], name_tok, source_base);
                count++;
            }
            prev_tt = TokenType.SEMICOLON;
            continue;
        }

        // Only a FunctionDeclaration (statement position) binds a lexical name;
        // a function *expression* like `x = function f(){}` or `(function f(){})`
        // binds nothing in the enclosing block. Same statement-position rule as
        // classes, `prev_tt` must be `;`/`{`/`}`. Capture it before the async
        // lookahead consumes prev_tt.
        bool fn_at_stmt_pos = class_is_declaration(prev_tt);

        // async function [*] Name (...) { ... }, only when "async" is
        // immediately followed by "function" (contextual keyword check).
        if (tt == TokenType.IDENTIFIER &&
            tok.str_value.len == 5 &&
            tok.str_value[0] == 'a' && tok.str_value[1] == 's' &&
            tok.str_value[2] == 'y' && tok.str_value[3] == 'n' &&
            tok.str_value[4] == 'c') {
            Token? peek_opt = self.lexer.next_token();
            if (catch _err5 = peek_opt) {
                break;
            }
            Token peek_tok = peek_opt;
            if (peek_tok.type != TokenType.FUNCTION) {
                // Not `async function`, this identifier is a plain expression
                // token; nothing further to do here (statement parsing handles it).
                prev_tt = peek_tok.type;
                continue;
            }
            // Fall through to the FUNCTION handling below via tok=peek_tok.
            tt = TokenType.FUNCTION;
        } else if (tt != TokenType.FUNCTION) {
            prev_tt = tt;
            continue;
        }

        // A function expression (not at statement position) binds no block name.
        if (!fn_at_stmt_pos) {
            prev_tt = TokenType.FUNCTION;
            continue;
        }

        // function [*] Name (...) { ... }, collect the binding name.
        {
            Token? star_opt = self.lexer.next_token();
            if (catch _err6 = star_opt) {
                break;
            }
            Token star_tok = star_opt;
            Token name_tok;
            bool fn_is_generator = star_tok.type == TokenType.STAR;
            if (fn_is_generator) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err7 = name_opt) {
                    break;
                }
                name_tok = name_opt;
            } else {
                name_tok = star_tok;
            }
            if (name_tok.type == TokenType.IDENTIFIER && count < capacity) {
                self.record_name_span(&spans[count], name_tok, source_base);
                // §14.2.11 step 3(a)(ii): this binding is instantiated to its
                // closure at block entry, not left in the TDZ. `pos_before` is
                // the declaration's `function` (or, for an async declaration,
                // `async`) keyword, which is where the caller re-enters the
                // ordinary statement path to compile it.
                spans[count].is_fn = true;
                spans[count].fn_pos = pos_before;
                count++;
            }
        }
        prev_tt = TokenType.SEMICOLON;
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

    return count;
}

// ES2024 §13.2.1: "It is a Syntax Error if the LexicallyDeclaredNames of
// StatementList contains any duplicate entries." `{ let x; class x {} }`,
// `{ function f(){} class f{} }` and `{ function f(){} let f; }` are all
// SyntaxErrors. The same rule is §14.12.1 for a switch's CaseBlock, whose
// clauses share one StatementList, so both call sites use this.
//
// Annex B's relaxation for two plain FunctionDeclarations sharing a name in
// one block is sloppy-mode only, so it never applies here: this engine is
// strict-only (see AGENTS.md). test262 states the split directly — the
// generated pair for `{ function f(){} function f(){} }` and its switch
// counterpart come from the `redeclare-allow-sloppy-function` templates and
// carry `flags: [onlyStrict]` with `negative: phase: parse`, i.e. strict code
// must reject exactly what sloppy code accepts.
//
// This applies only to a genuine BlockStatement or CaseBlock. A function
// BODY's top-level FunctionDeclarations are var-scoped rather than lexical,
// so they are not LexicallyDeclaredNames at all and never reach this check.
fn void? CompilerContext.check_duplicate_lexical_names(&self, NameSpan* spans, uint count) {
    for (uint ai = 0; ai < count; ai++) {
        for (uint bi = ai + 1; bi < count; bi++) {
            if (str_eq(self.name_span_text(spans[ai]),
                       self.name_span_text(spans[bi]))) {
                return self.fail("Identifier has already been declared")~;
            }
        }
    }
}

// ES2024 §16.1.1: a ScriptBody's LexicallyDeclaredNames must contain no
// duplicates, and §19.2.1.1 applies the same rule to an eval body. Colliding
// `let`/`const` are already caught at their declaration site by declare_var's
// scope walk, but two top-level `class` bindings never meet there, so the
// whole pre-scanned set is compared up front. Modules have their own,
// stricter check (check_module_duplicate_lexical_names).
fn void? CompilerContext.check_script_duplicate_lexical_names(&self) {
    if (self.is_module) return;
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    self.check_duplicate_lexical_names(&spans[0], n)!;
}

// ES2024 §13.2.1 / §14.12.1: the LexicallyDeclaredNames and VarDeclaredNames
// of a StatementList must not intersect, so `let x; var x;` (either order) at
// the same level is a SyntaxError. Scans forward from the current lexer
// position for the `var` names, so it must be called with the lexer parked
// just inside the body's opening brace, like the lexical pre-scans.
fn void? CompilerContext.check_lexical_var_conflicts(&self, NameSpan* lex_spans, uint num_lex) {
    if (num_lex == 0) return;
    NameSpan[MAX_PRESCAN_NAMES] var_spans;
    uint num_var = self.pre_scan_var_decls(&var_spans, MAX_PRESCAN_NAMES);
    for (uint li = 0; li < num_lex; li++) {
        char[] lname = self.name_span_text(lex_spans[li]);
        for (uint vi = 0; vi < num_var; vi++) {
            if (str_eq(lname, self.name_span_text(var_spans[vi]))) {
                return self.fail("lexical declaration cannot share a name with a var declaration")~;
            }
        }
    }
}

// Instantiate every top-level FunctionDeclaration of a block (or switch
// CaseBlock) at the block's entry, per ES2024 §14.2.11
// BlockDeclarationInstantiation step 3(a)(ii): unlike a `let`/`const`/`class`
// binding, which step 3(d) leaves uninitialized (the TDZ sentinel INITTZ
// writes), a FunctionDeclaration runs InstantiateFunctionObject right here,
// so the binding already holds its closure before the block's first statement
// executes. `{ f(); function f(){} }` therefore works, and papaparse's
// mutually-recursive block-scoped helpers resolve.
//
// Each declaration is compiled by re-entering the ordinary statement path
// with the lexer parked at its `function` / `async` keyword (the snapshot
// pre_scan_switch_lexical_decls stored in NameSpan.fn_lexer), so generators,
// async functions and Function.prototype.toString source retention all behave
// exactly as they do at the textual position. force_lexical_fn_decl is already
// set by the caller, so each one binds via PUTLEX into the lex_env PUSH_LEX
// just installed — late enough to capture this block's own lexical bindings,
// early enough that no statement has run.
//
// The names are left in `block_fn_spans` for function_declaration to skip when
// the textual pass reaches them again.
//
// Must be called after PUSH_LEX and the INITTZ loop, and before any statement.
fn void? CompilerContext.emit_block_scoped_fn_decls(&self, NameSpan* lex_spans, uint num_lex) {
    // The scan position to come back to: the block's first statement.
    LexerPos resume_pos = self.capture_lexer_pos();

    // Cleared for the duration: function_declaration consults it to SKIP an
    // already-instantiated declaration, and the declarations being compiled
    // right here are exactly the ones it must not skip. A declaration nested
    // inside one of these bodies belongs to its own block, which sets its own.
    NameSpan* outer_spans = self.block_fn_spans;
    uint outer_count = self.block_fn_count;
    self.block_fn_spans = null;
    self.block_fn_count = 0;
    defer {
        self.block_fn_spans = outer_spans;
        self.block_fn_count = outer_count;
    }

    for (uint i = 0; i < num_lex; i++) {
        if (!lex_spans[i].is_fn) continue;
        self.seek_lexer_to(lex_spans[i].fn_pos);
        self.pushback_count = 0;
        // statement() rather than function_declaration() directly: an
        // AsyncFunctionDeclaration is reached through the `async` contextual
        // keyword lookahead, which only statement() performs, and the recorded
        // position is on `async` for exactly that case.
        self.statement()!;
    }

    self.seek_lexer_to(resume_pos);
    self.pushback_count = 0;
}

// Parse a block: { statement* }
// If `check_directives` is true, checks for "use strict" directive prologue at the start.
// `is_param_body` marks a block that is the body scope of an enclosing
// parameter list, so a top-level `let`/`const` in it may not redeclare a
// parameter name. True for a function body (implied by `check_directives`,
// which only the function-body call sites pass) and for a `catch` block,
// whose relationship to its CatchParameter is the same one (§14.15.1).
fn void? CompilerContext.block(&self, bool check_directives, bool suppress_regex_hint = false,
                               bool is_param_body = false) {
    self.expect(TokenType.LBRACE)!;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Push a scope marker so duplicate let/const checks stop at this block
    // boundary, transparent to the parameter-redeclaration check when this
    // block is a parameter list's body scope.
    self.push_scope_marker(check_directives || is_param_body);

    // Pre-scan for let/const declarations at this block level so we can
    // TDZ-initialize them at block entry (before any code in the block runs).
    // A genuine BlockStatement (check_directives==false) also lexically scopes
    // its top-level FunctionDeclarations (ES2015 §13.2.6 / strict-mode
    // BlockDeclarationInstantiation): they bind into the block's own lex_env
    // via PUTLEX and vanish at POP_LEX, instead of leaking to the enclosing
    // var_env. A function *body* (check_directives==true) keeps its top-level
    // function declarations var-scoped, so it uses the let/const-only scan.
    NameSpan[MAX_PRESCAN_NAMES] lex_spans;
    uint num_lex;
    bool lexical_fns = !check_directives;
    if (lexical_fns) {
        num_lex = self.pre_scan_switch_lexical_decls(&lex_spans, MAX_PRESCAN_NAMES);
    } else {
        num_lex = self.pre_scan_lexical_decls(&lex_spans, MAX_PRESCAN_NAMES);
    }

    // ES2024 §13.2.1: "It is a Syntax Error if the LexicallyDeclaredNames of
    // StatementList contains any duplicate entries." `{ let x; class x {} }`,
    // `{ function f(){} class f{} }` and `{ function f(){} let f; }` are all
    // SyntaxErrors.
    //
    // The single exception is §B.3.2.1, which permits two plain
    // FunctionDeclarations to share a name in the same block —
    // `{ function f(){} function f(){} }` is legal, but pairing `function`
    // with `function*`, `async function`, `class` or `let` is not.
    // `redeclarable_fn` marks the plain-FunctionDeclaration case so only that
    // one pair is let through.
    //
    // Only a genuine BlockStatement is checked. In a function BODY
    // (check_directives == true, so lexical_fns == false) the top-level
    // FunctionDeclarations are var-scoped, not lexical, and redeclaring them
    // is allowed; that scan collects let/const only, so its names are already
    // covered by the declaration-site duplicate check in var_declaration.
    if (lexical_fns) {
        self.check_duplicate_lexical_names(&lex_spans[0], num_lex)!;
    }

    // §14.15.1: the CatchParameter's BoundNames must not appear in the catch
    // block's LexicallyDeclaredNames. A block-level FunctionDeclaration is
    // lexical in strict code, so `catch (e) { function e(){} }` is caught
    // here, where the pre-scan has already collected it; the declaration-site
    // walk in var_declaration only ever sees `let`/`const`. The B.3.4
    // exemption that lets a catch block's `var` reuse the name does not
    // extend to a lexical declaration.
    if (is_param_body && !check_directives) {
        for (uint i = 0; i < num_lex; i++) {
            self.check_lexical_redeclares_param(self.name_span_text(lex_spans[i]))!;
        }
    }

    // ES2024 §13.2.1 / §15.7.11 BlockDeclarationInstantiation: the
    // LexicallyDeclaredNames and VarDeclaredNames of this block must not
    // intersect. A `let x; var x;` (or vice versa) at the same block level
    // is a SyntaxError. Function bodies inherit the same rule (the body is
    // itself a block per §14.1).
    self.check_lexical_var_conflicts(&lex_spans[0], num_lex)!;

    // Push a new lexical scope for let/const/class/function declarations inside
    // this block. Skip when the block has none, saves an allocation on every
    // function call (most functions have no block-scoped variables).
    bool has_lex = num_lex > 0;
    if (has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
    }

    // Route top-level FunctionDeclarations in this block through PUTLEX into
    // the lex_env just pushed, rather than DECLVAR into the enclosing var_env.
    bool saved_force_lexical_fn_decl = self.force_lexical_fn_decl;
    if (lexical_fns && has_lex) {
        self.force_lexical_fn_decl = true;
    }

    // TDZ-initialize every let/const declaration found by the pre-scan.
    // This ensures that accessing the variable before its declaration
    // throws a ReferenceError (temporal dead zone) instead of finding
    // an outer `var` binding or returning undefined.
    //
    // A top-level FunctionDeclaration is skipped: §14.2.11 step 3(a)(ii)
    // instantiates it to its closure at block entry instead of leaving it
    // uninitialized, so poisoning it here would make a call placed before its
    // own textual position throw. emit_block_scoped_fn_decls below binds it.
    for (uint i = 0; i < num_lex; i++) {
        char[] name = self.name_span_text(lex_spans[i]);
        if (!lex_spans[i].is_fn) {
            uint name_idx = self.add_string_constant(name);
            self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
        }

        // Mark the outer scope_stack entry as captured so that the compiler
        // emits GETVAR instead of LDREG for this variable.  Without this,
        // a register-cached value from an outer scope would bypass the new
        // lex_env: the TDZ sentinel for a let/const/class, and the block's own
        // closure for a FunctionDeclaration, which shadows the outer binding
        // for the whole block just the same.
        for (uint j = 0; j < saved_depth; j++) {
            if (str_eq(self.scope_stack[j].name, name)) {
                self.scope_stack[j].is_captured = true;
                self.has_captured_local = true;
                break;
            }
        }
    }

    if (check_directives) {
        self.parse_directives()!;
    }

    // Instantiate the surviving declaration of every duplicated function name
    // (see hoisted_defer_names). This runs after PUSH_LEX/INITTZ, so the closure
    // captures this block's lexical bindings, and before any statement, so a
    // property stored on it later is never overwritten by a rebinding.
    //
    // Gated on check_directives, which is set only for a body block (the one
    // the hoist pass that filled these records ran for). A nested block is
    // compiled by the same context and would otherwise re-emit them, rebinding
    // the function partway through the scope. Arrow bodies never reach block(),
    // so they call emit_hoisted_fn_decls themselves.
    if (check_directives) { self.emit_hoisted_fn_decls(); }

    // §14.2.11 step 3(a)(ii): instantiate this block's own top-level
    // FunctionDeclarations before any statement runs. Saved/restored around the
    // block so a nested block skips only its OWN declarations.
    NameSpan* saved_block_fn_spans = self.block_fn_spans;
    uint saved_block_fn_count = self.block_fn_count;
    defer {
        self.block_fn_spans = saved_block_fn_spans;
        self.block_fn_count = saved_block_fn_count;
    }
    if (lexical_fns && has_lex) {
        self.block_fn_spans = &lex_spans[0];
        self.block_fn_count = num_lex;
        self.emit_block_scoped_fn_decls(&lex_spans[0], num_lex)!;
    } else {
        self.block_fn_spans = null;
        self.block_fn_count = 0;
    }

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        self.statement()!;
    }

    self.force_lexical_fn_decl = saved_force_lexical_fn_decl;

    self.expect(TokenType.RBRACE)!;
    // A `}` closing a BlockStatement is a statement boundary: per the
    // ECMAScript lexical grammar, a following `/` starts a
    // RegularExpressionLiteral, not division (see Lexer.note_block_close doc).
    // Function bodies compiled as *expressions* (function expressions, arrow
    // bodies used as call arguments, etc.) are not statement boundaries, the
    // whole `function(){...}` is itself an operand, so a following `/` must
    // be read as division. Callers pass suppress_regex_hint=true for those.
    if (!suppress_regex_hint) {
        self.lexer.note_block_close();
    }

    // Pop the lexical scope, removing any let/const bindings from this block
    if (has_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }

    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

// Emit the environment store for a declared variable (PUTVAR or PUTLEX/PUTLEX_C).
fn void CompilerContext.emit_var_store(&self, ushort reg, uint name_idx, bool is_lexical, bool is_const) {
    if (is_lexical) {
        if (is_const) {
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)reg, name_idx);
        } else {
            self.emit_a_bc(Opcode.PUTLEX, (uint)reg, name_idx);
        }
        // The PUTLEX/PUTLEX_C above publishes the binding's initial value to
        // the lex_env and replaces the INITTZ sentinel, the TDZ period ends
        // here.  Clear `is_tdz` on the inner-most matching scope_stack entry
        // so subsequent reads inside the same scope can use the fast register
        // path again.
        if (name_idx < self.const_count) {
            HString* hs = (HString*)self.constants[name_idx].get_heapptr();
            if (hs != null) {
                char[] bname = hs.get_data();
                for (uint i = self.scope_depth; i > 0; i--) {
                    uint idx = i - 1;
                    if (self.scope_stack[idx].kind == SCOPEMARK) continue;
                    if (str_eq(self.scope_stack[idx].name, bname)) {
                        self.scope_stack[idx].is_tdz = false;
                        break;
                    }
                }
            }
        }
    } else {
        // DECLVAR declares the binding in the immediate var_env (function-scoped).
        // PUTVAR (plain assignment) walks the chain to update existing bindings.
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
    }
}

// Parse var/let/const declaration.
fn void? CompilerContext.var_declaration(&self) {
    Token decl_tok = self.advance()!;
    bool is_const = (decl_tok.type == TokenType.CONST);
    bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
    ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

    // var declarations are hoisted to function scope, need env allocation.
    if (!is_lexical) {
        self.has_local_bindings = true;
    }

    // Parse one or more variable declarators
    for (;;) {
        TokenType next = self.peek_type();

        if (next == TokenType.LBRACKET) {
            self.advance()!; // consume '['
            self.array_destructure(kind, is_lexical, is_const)!;
            self.try_skip_ts_type_annotation()!;
        } else if (next == TokenType.LBRACE) {
            self.advance()!; // consume '{'
            self.object_destructure(kind, is_lexical, is_const)!;
            self.try_skip_ts_type_annotation()!;
        } else {
            // Per ES2024 §13.3.1, BindingIdentifier is an Identifier or
            // `await` in a non-module, non-async context. We're strict-only,
            // so `yield` is always reserved and never a binding name.
            Token name_tok;
            // `await` reaches here only when the context already permits it as
            // an identifier, so the context-blind is_restricted_name check
            // below must not re-reject it, it applies to the plain Identifier
            // path only. `await` is an identifier only outside a module AND
            // outside an async function/arrow (§13.1.1).
            bool ctx_keyword_ident = false;
            if (next == TokenType.IDENTIFIER) {
                name_tok = self.advance()!;
            } else if (self.await_is_identifier(next)) {
                // BindingIdentifier position: an escaped `await` is a plain
                // name, not the terminal, so consume it as an IdentifierName.
                name_tok = self.advance(true)!;
                ctx_keyword_ident = true;
            } else {
                self.record_error("expected a binding identifier after the declaration keyword");
                return COMPILE_ERROR~;
            }
            if (!ctx_keyword_ident && is_restricted_name(name_tok.str_value)) {
                return self.fail("reserved word cannot be used as a binding identifier")~;
            }
            // Intern now: an escaped identifier borrows the lexer's shared
            // ident_buf scratch, which the initializer or a later declarator
            // in this same statement will overwrite. declare_var stores this
            // slice into scope_stack, which outlives the current token.
            name_tok.str_value = ((Heap*)self.heap).str_intern(name_tok.str_value).get_data();
            self.try_skip_ts_definite_marker()!;
            self.try_skip_ts_type_annotation()!;
            ushort reg;
            bool already_declared = false;
            if (!is_lexical) {
                self.check_var_lex_conflict(name_tok.str_value, kind)!;
                // var declarations: check if already declared (from hoisting
                // or from an outer var declaration in the same function).
                // If so, reuse the existing register and skip DECLVAR/LDUNDEF.
                // Capture-blind lookup: a captured var must still be detected
                // here, or a bare `var x;` redeclaration would emit
                // LDUNDEF+DECLVAR and clobber the live env value.
                ushort? existing = self.find_local_reg(name_tok.str_value);
                if (try er = existing) {
                    reg = er;
                    already_declared = true;
                } else {
                    reg = self.declare_var(name_tok.str_value, kind);
                }
            } else {
                // Check for duplicate let/const in the same block scope (ES6 §13.3.1)
                if (is_lexical) {
                    self.check_lexical_redeclares_param(name_tok.str_value)!;
                    uint i = self.scope_depth;
                    while (i > 0) {
                        i--;
                        // Stop at VAR entries (function-scope boundary) or
                        // SCOPEMARK entries (block-scope boundary).
                        if (self.scope_stack[i].kind == VAR || self.scope_stack[i].kind == SCOPEMARK) break;
                        if (str_eq(self.scope_stack[i].name, name_tok.str_value) &&
                            (self.scope_stack[i].kind == LET || self.scope_stack[i].kind == CONST)) {
                            return COMPILE_ERROR~;
                        }
                    }
                }
                reg = self.declare_var(name_tok.str_value, kind);
            }
            ushort saved_reg = self.next_reg;

            // Optional initializer
            bool has_init = false;
            if (self.match(TokenType.ASSIGN)) {
                // ES2015 §14.1.20 SetFunctionName: pass the var name to a
                // following anonymous function expression so `var f = function(){}`
                // gives f the name "f". Set the inferred name unconditionally
                // (overwriting any stale value from a previous declarator in the
                // same var statement); function_expr clears it after use.
                self.has_inferred_name = true;
                ushort nlen = (ushort)name_tok.str_value.len;
                if (nlen < 128) {
                    for (ushort i = 0; i < nlen; i++) self.inferred_name_buf[i] = name_tok.str_value[i];
                    self.inferred_name_len = nlen;
                } else {
                    self.has_inferred_name = false;
                }
                ushort val_reg = self.assignment_expr()!;
                if (val_reg != reg) {
                    self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                }
                self.free_reg(val_reg);
                has_init = true;
            } else if (!already_declared) {
                if (is_const) {
                    return COMPILE_ERROR~;
                }
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }

            // Store in the environment so inner functions can find it
            // var → var_env (function-scoped), let/const → lex_env (block-scoped)
            // For already-declared vars, only emit store if there's an initializer
            if (!already_declared || has_init) {
                uint name_idx = self.add_string_constant(name_tok.str_value);
                bool slot_global = self.is_global && !is_lexical
                    && self.is_slot_global_name_index(name_idx);
                if (slot_global) {
                    // A REGISTER-RESIDENT global: the initializer already landed
                    // in the home register (LDREG above). The global property is
                    // only a mirror synced once at end of script, so skip the
                    // per-initializer env write entirely.
                } else if (self.is_global && !is_lexical && has_init) {
                    // `var x = <expr>` at global scope is a declaration (already
                    // instantiated by the hoist pass) followed by a plain
                    // assignment, so emit the assignment as a value-only update
                    // of the existing global binding.
                    self.emit_a_bc(Opcode.PUTVAR, (uint)reg, name_idx);
                } else if (!is_lexical && !has_init) {
                    // Initializer-less `var x;` carries no value: an existing
                    // global binding must keep its current one, which plain
                    // DECLVAR would overwrite with undefined on re-execution.
                    self.emit_a_bc(Opcode.DECLVAR_HOIST, (uint)reg, name_idx);
                } else {
                    self.emit_var_store(reg, name_idx, is_lexical, is_const);
                }
            }

            // At global scope, free the var register and any leaked temporaries
            // from the initializer evaluation.  Global vars use PUTVAR/GETVAR
            // at runtime, the register is only needed briefly as the PUTVAR source.
            // Lexical declarations (let/const) at global scope have their registers
            // managed by pop_scope_to() from the enclosing block() or from the
            // top-level compile() cleanup. A REGISTER-RESIDENT global keeps its
            // register as the live home slot for the whole top-level body.
            if (self.is_global) {
                if (!is_lexical && !self.is_slot_global_name(name_tok.str_value)) {
                    self.free_reg(reg);
                }
                self.free_regs_to(saved_reg);
            }
        }

        if (!self.match(TokenType.COMMA)) {
            break;
        }
    }

    self.expect_semicolon_or_asi()!;
}

// Parse if/else statement.
fn void? CompilerContext.if_statement(&self) {
    self.expect(TokenType.IF)!;
    self.expect(TokenType.LPAREN)!;

    // In eval mode, the if-statement always produces a completion value.
    // Per spec §14.6.2: if-false-no-else returns NormalCompletion(undefined);
    // if-with-else returns UpdateEmpty(branchCompletion, undefined).
    // Either way, any prior completion value is replaced, reset to undefined
    // now so an empty or not-taken branch leaves the correct undefined result.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Emit conditional jump (skip then-branch if false)
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_expr_reg(cond_reg);

    // Compile then-branch. The `)` just consumed closes the if-clause, not an
    // operand, so a following `/` must start a RegularExpressionLiteral (see
    // Lexer.note_block_close doc; B2).
    self.lexer.note_block_close();
    self.statement_body()!;

    if (self.match(TokenType.ELSE)) {
        // Emit jump over else-branch
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // Compile else-branch. `else` is a keyword, never an operand, so the
        // same regex hint applies here too.
        self.lexer.note_block_close();
        self.statement_body()!;

        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

// Parse while statement.
fn void? CompilerContext.while_statement(&self) {
    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    // --- Rotated while-loop layout ---
    //
    //   JUMP → cond_label              (zero-iteration check)
    //   body_label:
    //     <body>
    //   cond_label:                    ← continue targets HERE
    //     <condition>
    //     IF_TRUE → body_label         (back edge; fused → JMP_LT etc.)
    //   exit:                          ← break patches here
    //
    // The condition appears BEFORE the body in source, so we save the lexer
    // state here, skip the condition tokens, compile the body, then restore
    // and compile the condition.  This mirrors the for-loop's rotation.

    // ----------------------------------------------------------------
    // Step 0: Save lexer state at start of condition.
    // ----------------------------------------------------------------
    uint  _cond_pos; uint  _cond_line; uint  _cond_col;
    Token _cond_cur; Token _cond_look; bool  _cond_haslk;
    Token _cond_push; bool _cond_haspb; bool _cond_slt;
    uint  _cond_pbc;  Token[4] _cond_pbs;
    _cond_pos   = self.lexer.pos;
    _cond_line  = self.lexer.line;
    _cond_col   = self.lexer.col;
    _cond_cur   = self.lexer.current;
    _cond_look  = self.lexer.lookahead;
    _cond_haslk = self.lexer.has_lookahead;
    _cond_push  = self.lexer.pushed_back;
    _cond_haspb = self.lexer.has_pushed_back;
    _cond_slt   = self.lexer.seen_line_term;
    _cond_pbc   = self.pushback_count;
    _cond_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 1: Check for while(true), constant true, skip rotate overhead.
    //         Also detect simple `<ident> <relop> <numeric literal>` condition.
    // ----------------------------------------------------------------
    bool is_const_true = false;
    bool has_simple_cond = false;
    double simple_cond_rhs = 0.0;
    Opcode simple_cond_op = Opcode.LT;
    ushort pinned_rhs_reg = 0;

    // Probe up to 4 tokens to detect simple patterns (only when pushback is clean).
    if (_cond_pbc == 0 && !_cond_haspb && !_cond_haslk) {
        Token? t1o = self.lexer.next_token();
        if (try t1 = t1o) {
            // while(true), 'true' is lexed as an IDENTIFIER with str_value "true"
            if (t1.type == TokenType.IDENTIFIER && str_eq(t1.str_value, "true")) {
                Token? t2o = self.lexer.next_token();
                if (try t2 = t2o) {
                    if (t2.type == TokenType.RPAREN) {
                        is_const_true = true;
                    } else {
                        self.pushback(t2);
                    }
                }
            }
            // while(ident <relop> number)
            if (!is_const_true && t1.type == TokenType.IDENTIFIER) {
                Token? t2o = self.lexer.next_token();
                if (try t2 = t2o) {
                    Token? t3o = self.lexer.next_token();
                    if (try t3 = t3o) {
                        Token? t4o = self.lexer.next_token();
                        if (try t4 = t4o) {
                            bool is_relop = (t2.type == TokenType.LT || t2.type == TokenType.LE
                                          || t2.type == TokenType.GT || t2.type == TokenType.GE);
                            bool is_num   = (t3.type == TokenType.NUMBER);
                            bool is_rp    = (t4.type == TokenType.RPAREN);
                            if (is_relop && is_num && is_rp) {
                                has_simple_cond = true;
                                simple_cond_rhs = t3.num_value;
                                switch (t2.type) {
                                    case TokenType.LT: simple_cond_op = Opcode.LT;
                                    case TokenType.LE: simple_cond_op = Opcode.LE;
                                    case TokenType.GT: simple_cond_op = Opcode.GT;
                                    default:           simple_cond_op = Opcode.GE;
                                }
                            }
                        }
                    }
                }
            }
            if (!is_const_true) {
                self.pushback(t1);
            }
        }
        // Restore lexer to start of condition.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
    }

    // ----------------------------------------------------------------
    // Step 2: Pre-load pinned RHS register (before initial JUMP).
    // ----------------------------------------------------------------
    if (has_simple_cond) {
        pinned_rhs_reg = self.alloc_reg();
        int int_rhs = (int)simple_cond_rhs;
        if ((double)int_rhs == simple_cond_rhs
            && int_rhs >= bytecode::MIN_SBC && int_rhs <= bytecode::MAX_SBC) {
            self.emit_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs);
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx);
        }
    }

    // ----------------------------------------------------------------
    // Step 3: Emit initial JUMP → cond_label and record body_label.
    // ----------------------------------------------------------------
    // ES spec §14.7.3.2: while starts with V=undefined. In eval mode, reset
    // eval_acc_reg before the loop so a zero-iteration while returns undefined.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    uint cond_jump = 0;
    if (!is_const_true) {
        cond_jump = self.emit_jump(Opcode.JUMP);  // forward → cond_label
    }
    uint body_label = self.code_count;

    // ----------------------------------------------------------------
    // Step 4: Skip condition tokens (no code emitted) and consume ')'.
    // ----------------------------------------------------------------
    // skip_expr_lex scans until `)` at depth 0, leaving it in pushed_back.
    self.skip_expr_lex();
    self.expect(TokenType.RPAREN)!;  // consume ')'
    // The `)` just consumed closes the while-clause, not an operand, so a
    // following `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();

    // ----------------------------------------------------------------
    // Step 5: Push loop (continue_target = body_label placeholder;
    //          updated to cond_label in Step 7).
    // ----------------------------------------------------------------
    self.push_loop(body_label, true);
    // In eval mode, reset eval_acc_reg at the top of each body iteration.
    // This ensures break with empty body leaves undefined (not a stale value
    // from a previous iteration) and matches spec §14.7.3.2 UpdateEmpty.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    self.statement_body()!;

    // Save post-body lexer state, outer parser resumes here after return.
    uint  _post_pos; uint  _post_line; uint  _post_col;
    Token _post_cur; Token _post_look; bool  _post_haslk;
    Token _post_push; bool _post_haspb; bool _post_slt;
    uint  _post_pbc;  Token[4] _post_pbs;
    _post_pos   = self.lexer.pos;   _post_line  = self.lexer.line;   _post_col   = self.lexer.col;
    _post_cur   = self.lexer.current; _post_look  = self.lexer.lookahead;
    _post_haslk = self.lexer.has_lookahead; _post_push  = self.lexer.pushed_back;
    _post_haspb = self.lexer.has_pushed_back; _post_slt = self.lexer.seen_line_term;
    _post_pbc   = self.pushback_count; _post_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 6: cond_label, patch initial JUMP and update continue_target.
    // ----------------------------------------------------------------
    uint cond_label = self.code_count;
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = cond_label;
    }
    if (!is_const_true) {
        self.patch_jump(cond_jump);
    }

    // ----------------------------------------------------------------
    // Step 7: Compile condition with IF_TRUE back edge to body_label.
    // ----------------------------------------------------------------
    if (is_const_true) {
        // while(true), unconditional back edge.
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, back));
    } else if (has_simple_cond) {
        // Restore lexer to condition start, compile with pinned RHS.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
        Token ident_tok = self.advance()!;
        Token _relop    = self.advance()!;   // consume relop
        Token _num_tok  = self.advance()!;   // consume NUMBER (value in pinned_rhs_reg)
        self.expect(TokenType.RPAREN)!;      // consume ')'

        ushort lhs_reg = self.alloc_reg();
        // At global scope read through emit_ident_read, so a proven primitive-only
        // global gets the guard-free GETGLOBAL_PRIM rather than a guarded GETVAR.
        if (!self.is_global) {
            if (try reg = self.resolve_var(ident_tok.str_value)) {
                if (reg != lhs_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)lhs_reg, (uint)reg, 0);
                }
            } else {
                uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
            }
        } else {
            uint name_idx2 = self.add_string_constant(ident_tok.str_value);
            self.emit_ident_read((uint)lhs_reg, name_idx2);
        }
        ushort cmp_res = self.alloc_reg();
        self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
        self.free_reg(lhs_reg);
        self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cmp_res, body_label);
        self.free_reg(cmp_res);
        self.free_reg(pinned_rhs_reg);
    } else {
        // General condition: restore and re-compile normally.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
        ushort cond_reg = self.expression()!;
        self.expect(TokenType.RPAREN)!;
        self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cond_reg, body_label);
        self.free_expr_reg(cond_reg);
    }

    // exit: pop_loop patches all break jumps and resolves continue patches.
    self.pop_loop();

    // Restore the lexer to the position after the body.
    self.lexer.pos = _post_pos; self.lexer.line = _post_line; self.lexer.col = _post_col;
    self.lexer.current = _post_cur; self.lexer.lookahead = _post_look;
    self.lexer.has_lookahead = _post_haslk; self.lexer.pushed_back = _post_push;
    self.lexer.has_pushed_back = _post_haspb; self.lexer.seen_line_term = _post_slt;
    self.pushback_count = _post_pbc; self.pushback_stack = _post_pbs;

    self.match(TokenType.SEMICOLON);
}

// Copy a classic for-loop's lexical head bindings into a fresh environment
// (ES2015 §14.7.4.9 CreatePerIterationEnvironment).  All values must be read
// before the old environment is popped: after the pop, later bindings in a
// multi-declarator head are no longer reachable.
fn void CompilerContext.emit_create_per_iteration_env(&self,
    uint[] name_idxs, bool[] is_const, uint count)
{
    ushort[8] temps;
    for (uint i = 0; i < count; i++) {
        temps[i] = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)temps[i], name_idxs[i]);
    }
    self.emit_simple(Opcode.POP_LEX);
    self.emit_simple(Opcode.PUSH_LEX);
    for (uint i = 0; i < count; i++) {
        Opcode store_op = is_const[i] ? Opcode.PUTLEX_C : Opcode.PUTLEX;
        self.emit_a_bc(store_op, (uint)temps[i], name_idxs[i]);
    }
    for (uint i = count; i > 0; i--) {
        self.free_reg(temps[i - 1]);
    }
}

// Parse for statement (basic for, for-in, for-of, for-await-of).
fn void? CompilerContext.for_statement(&self) {
    self.expect(TokenType.FOR)!;

    // `for await (LHS of expr)`, ES2018 async iteration (§14.7.5). Only valid
    // inside an async function/method or at module top level (both set is_async).
    // The async-ness rides on `for_is_await` and is threaded to emit_forof; the
    // for-in and C-style forms reject it below (no async for-in / async C-for).
    bool for_is_await = false;
    if (self.check(TokenType.AWAIT)) {
        if (!self.is_async) {
            return self.fail("'for await' is only valid in an async function or at module top level")~;
        }
        self.advance()!; // consume 'await'
        for_is_await = true;
    }

    self.expect(TokenType.LPAREN)!;

    // `for (using x of ...)` / `for (await using x of ...)`: explicit
    // resource management (ES2025) is not implemented. statement() rejects
    // the statement-level `using` introducer; catch the for-head form here
    // (with an optional `await` prefix) with the same message so it is not
    // misparsed as an identifier.
    if (self.peek_type() == TokenType.IDENTIFIER || self.check(TokenType.AWAIT)) {
        Lexer saved_u = *self.lexer;
        Token? u_opt = self.advance();
        bool is_using = false;
        if (try u = u_opt) {
            if (u.str_value.len == 5
                && u.str_value[0] == 'u' && u.str_value[1] == 's'
                && u.str_value[2] == 'i' && u.str_value[3] == 'n'
                && u.str_value[4] == 'g') {
                is_using = true;
            } else if (u.type == TokenType.AWAIT
                || (u.str_value.len == 5
                    && u.str_value[0] == 'a' && u.str_value[1] == 'w'
                    && u.str_value[2] == 'a' && u.str_value[3] == 'i'
                    && u.str_value[4] == 't')) {
                // `await using`: `await` may lex as the AWAIT token (async
                // context) or as an identifier.
                if (self.peek_type() == TokenType.IDENTIFIER) {
                    Token? u2_opt = self.advance();
                    if (try u2 = u2_opt) {
                        if (u2.str_value.len == 5
                            && u2.str_value[0] == 'u' && u2.str_value[1] == 's'
                            && u2.str_value[2] == 'i' && u2.str_value[3] == 'n'
                            && u2.str_value[4] == 'g') {
                            is_using = true;
                        }
                    }
                }
            }
        }
        *self.lexer = saved_u;
        if (is_using) {
            return self.fail("using declarations are not supported")~;
        }
    }

    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Track for-init var so we can emit PUTVAR after the increment to sync
    // the register-cached value back to the environment (needed so closures
    // inside the loop and code after the loop see the correct final value).
    bool has_for_var = false;
    bool is_lexical = false;
    ushort for_var_reg = 0;
    uint for_var_name_idx = 0;

    // Per-iteration lexical environment tracking: when a for-init let/const binding
    // is captured by a closure inside the loop body, each iteration must get its own
    // environment so closures created in different iterations see distinct values
    // (ES2015 §14.7.4.2 CreatePerIterationEnvironment). Tracked here and emitted
    // as a prologue at the start of each body iteration (see body_label below).
    //
    // Only bindings actually captured by a nested closure need per-iter envs;
    // common non-capturing loops pay no overhead. The pre_scan_captures pass
    // runs for both function and global scope, so is_captured_name works
    // uniformly.
    //
    // The env is authoritative: at non-global scope captures use INC_VAR
    // (env-resident); at global scope primary_expr always uses GETVAR and i++
    // compiles to INC_VAR via a peephole, keeping the env in sync.
    bool needs_periterenv = false;
    char[][8] periterenv_names;
    uint[8] periterenv_name_idxs;
    bool[8] periterenv_is_const;
    uint periterenv_count = 0;

    // Check for for-in / for-of
    TokenType next_tt = self.peek_type();

    // Check for bare for-of/for-in with a plain identifier LHS: for (x of expr) / for (x in expr)
    if (next_tt == TokenType.IDENTIFIER) {
        Token id_tok = self.advance()!;
        if (try tok2 = self.lexer.peek()) {
            if (token_is_of(tok2)) {
                // `of` is only a for-of keyword when it is not part of an arrow-function
                // parameter list. For example, `for (async of => {}; ...)` is a plain
                // for-loop whose init is the call expression `async(of => {})`.
                Token of_tok = self.advance()!;
                bool is_arrow = self.check_arrow();
                self.pushback(of_tok);
                self.pushback(id_tok);
                if (!is_arrow) {
                    // §14.7.5: `for ( [lookahead ∉ { let [, async of }]
                    // LeftHandSideExpression of AssignmentExpression )`. The
                    // token pair `async of` at the head's start is excluded
                    // outright, so a variable actually named `async` cannot be
                    // the loop target of a for-of — `for ((async) of [1])` and
                    // `for (o.async of [1])` are the spellings that work.
                    // (`for (async of => 1;;)` is a different parse, handled
                    // by the arrow test above; `for await` has its own head
                    // production with no such restriction.)
                    // The restriction is on the literal TOKEN `async`, so an
                    // escaped spelling (`async`) is not excluded — it is
                    // an IdentifierReference that merely denotes the same
                    // binding (test262 for-of/head-lhs-async-escaped).
                    if (!for_is_await && !id_tok.has_escape
                        && str_eq(id_tok.str_value, "async")) {
                        return self.fail("a for-of head may not begin with the token pair 'async of'")~;
                    }
                    // consume the tokens we pushed back; tok2/of_tok is already consumed
                    self.advance()!; // id_tok
                    self.advance()!; // of_tok
                    ushort iter_reg = self.assignment_expr()!;
                    self.expect(TokenType.RPAREN)!;
                    self.emit_forof_loop(id_tok.str_value, iter_reg, saved_scope, saved_reg, false, false, true, for_is_await)!;
                    return;
                }
            } else if (tok2.type == TokenType.IN) {
                if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
                self.advance()!;  // consume "in"
                ushort obj_reg = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                self.emit_bare_forin_loop(id_tok.str_value, obj_reg, saved_scope, saved_reg)!;
                return;
            } else {
                self.pushback(id_tok);
            }
        } else {
            self.pushback(id_tok);
        }
    }

    // Check for parenthesized identifier LHS: for ((x) of expr) / for ((x) in expr).
    // Per ES2015 §13.7.5 a parenthesized LeftHandSideExpression is a valid for-of/in
    // head when the inner expression is an assignment target. The simplest common case
    // is a parenthesized identifier, detect it via a three-token lookahead:
    // '(' IDENTIFIER ')' followed by 'of' or 'in'.
    if (next_tt == TokenType.LPAREN) {
        uint saved_pos  = self.lexer.pos;
        uint saved_line = self.lexer.line;
        uint saved_col  = self.lexer.col;
        Token saved_cur  = self.lexer.current;
        Token saved_look = self.lexer.lookahead;
        bool  saved_hlk  = self.lexer.has_lookahead;
        Token saved_push = self.lexer.pushed_back;
        bool  saved_hpb  = self.lexer.has_pushed_back;
        bool  saved_slt  = self.lexer.seen_line_term;
        uint  saved_pbc  = self.pushback_count;
        Token[4] saved_pbs = self.pushback_stack;

        self.advance()!; // consume '('
        bool paren_is_forof = false;
        bool paren_is_forin = false;
        char[] paren_id_name;

        if (self.peek_type() == TokenType.IDENTIFIER) {
            Token inner_tok = self.advance()!;
            if (self.match(TokenType.RPAREN)) {
                if (try pt = self.lexer.peek()) {
                    if (token_is_of(pt)) {
                        paren_is_forof = true;
                        paren_id_name = inner_tok.str_value;
                    } else if (pt.type == TokenType.IN) {
                        paren_is_forin = true;
                        paren_id_name = inner_tok.str_value;
                    }
                }
            }
        }

        self.lexer.pos             = saved_pos;
        self.lexer.line            = saved_line;
        self.lexer.col             = saved_col;
        self.lexer.current         = saved_cur;
        self.lexer.lookahead       = saved_look;
        self.lexer.has_lookahead   = saved_hlk;
        self.lexer.pushed_back     = saved_push;
        self.lexer.has_pushed_back = saved_hpb;
        self.lexer.seen_line_term  = saved_slt;
        self.pushback_count        = saved_pbc;
        self.pushback_stack        = saved_pbs;

        if (paren_is_forof) {
            self.advance()!; // consume '('
            self.advance()!; // consume identifier
            self.advance()!; // consume ')'
            self.advance()!; // consume 'of'
            ushort iter_reg = self.assignment_expr()!;
            self.expect(TokenType.RPAREN)!;
            self.emit_forof_loop(paren_id_name, iter_reg, saved_scope, saved_reg, false, false, true, for_is_await)!;
            return;
        }
        if (paren_is_forin) {
            if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
            self.advance()!; // consume '('
            self.advance()!; // consume identifier
            self.advance()!; // consume ')'
            self.advance()!; // consume 'in'
                ushort obj_reg = self.expression()!;
                if (is_lexical) {
                    // Keep the head TDZ environment alive beneath a distinct
                    // iteration environment so closures created by the RHS
                    // retain the uninitialised binding.
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                }
                self.expect(TokenType.RPAREN)!;

            self.emit_bare_forin_loop(paren_id_name, obj_reg, saved_scope, saved_reg)!;
            return;
        }
    }

    // Check for bare for-of/for-in with a member-expression LHS:
    // for (obj.prop of expr) / for (obj[key] in expr). Per ES2015
    // §13.7.5.1 the head's AssignmentExpression may be any valid
    // assignment target, not just an identifier, member expressions
    // are the common non-identifier case (destructuring patterns are
    // handled separately and are out of scope here, tracked as B37).
    //
    // Detection is speculative: save the lexer, try to compile the LHS
    // as a member expression, then check for a following `of`/`in`. If
    // that shape doesn't hold, restore and fall through to the general
    // expression-init path below (unchanged behavior for non-member,
    // non-for-of/in expressions like `for (i = 0; ...)`).
    if (next_tt != TokenType.SEMICOLON && next_tt != TokenType.VAR
        && next_tt != TokenType.LET && next_tt != TokenType.CONST
        && next_tt != TokenType.LBRACKET && next_tt != TokenType.LBRACE) {
        // Destructuring LHS (`[a, b] of arr` / `{x} of arr`) is handled
        // by the bare-destructuring branch below, member_expr cannot
        // parse a `[...]`/`{...}` pattern but would still emit code for
        // any elements (e.g. GETVAR for a bare `[x]` element) that
        // survives the lexer restore, leaving a stray GETVAR in the
        // bytecode before the real destructure.  Skip member_expr here
        // when LHS opens with `[` or `{`.
        ForLhsSnapshot lhs_snap = self.save_lhs_snapshot();
        ushort saved_next_reg = self.next_reg;
        uint saved_code_count = self.code_count;
        // The speculative parse can record a compile error (e.g. `yield` as
        // a for-head LHS in a generator: primary_expr's YIELD case rejects
        // a non-AssignmentExpression position via fail()); save the error
        // state so a failed probe falls through to the real init parse.
        char[512] saved_err_msg = self.lexer.err_msg;
        uint saved_err_line = self.lexer.err_line;
        uint saved_err_col = self.lexer.err_col;

        bool is_member_head = false;
        bool head_is_of = false;

        if (try mreg = self.call_expr()) {
            if (self.last_was_member()) {
                self.free_reg(self.member_prop());
                self.free_reg(self.member_obj());
                self.free_reg(mreg);
                if (try tok3 = self.lexer.peek()) {
                    if (token_is_of(tok3)) {
                        is_member_head = true;
                        head_is_of = true;
                    } else if (tok3.type == TokenType.IN) {
                        is_member_head = true;
                        head_is_of = false;
                    }
                }
            }
        }

        // Restore lexer + register + code state; the LHS is re-parsed from
        // source once per iteration (see emit_forof_loop_member/
        // emit_forin_loop_member), so nothing from this speculative
        // parse should be kept. The code buffer must be rewound too:
        // member_expr() emits GETPROP/GETPROPC into it, and leaving those
        // behind executes the LHS once before the loop, clobbering whichever
        // live local happens to own the scratch register.
        self.restore_lhs_snapshot(lhs_snap);
        self.next_reg = saved_next_reg;
        self.code_count = saved_code_count;
        self.discard_member_head_state();
        self.lexer.err_msg = saved_err_msg;
        self.lexer.err_line = saved_err_line;
        self.lexer.err_col = saved_err_col;

        if (is_member_head) {
            // Re-consume the LHS only to advance the lexer past it; the store
            // itself is re-parsed from lhs_snap once per iteration (see
            // emit_member_lhs_store), so this parse's code and registers are
            // dead. Discard both: the emitted GETPROP/LDCONST would otherwise
            // run once before the loop and clobber a live local's home
            // register (the scratch regs are allocated from next_reg, which
            // at this point still overlaps the enclosing function's locals).
            uint pre_code = self.code_count;
            ushort pre_reg = self.next_reg;
            // call_expr, not member_expr: the LHS can be a call followed by
            // a member (`for (foo().x of [])`), and the re-consume must
            // advance past the whole shape or the `(` leaks into the head.
            self.call_expr()!;
            self.code_count = pre_code;
            self.free_regs_to(pre_reg);
            self.discard_member_head_state();
            self.advance()!;  // consume "of" or "in"

            if (head_is_of) {
                ushort iter_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;
                self.emit_forof_loop_member(lhs_snap, iter_reg, saved_scope, saved_reg, for_is_await)!;
            } else {
                if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
                ushort obj_reg = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                self.emit_forin_loop_member(lhs_snap, obj_reg, saved_scope, saved_reg)!;
            }
            return;
        }
    }

    // Check for bare for-of/for-in with a destructuring pattern LHS:
    // for ([a, b] of arr) / for ([a, b] in obj) / for ({x, y} of arr).
    // Per ES2015 §13.7.5 the destructuring target is in the enclosing
    // scope (no new block scope per iteration), and the bindings are
    // var-scoped. Scan the pattern with the lexer only (no code emission
    //, any speculative compile of the LHS would leak GETVAR/INC/etc.
    // instructions into the actual code buffer before the lexer is
    // restored).  Save lexer state, peek past the pattern for `of`/`in`,
    // restore, then dispatch.
    if (next_tt == TokenType.LBRACKET || next_tt == TokenType.LBRACE) {
        bool is_bare_destr = false;
        bool bare_is_of = false;

        // Save lexer state for the speculative pattern scan. Same
        // technique as the `let [x] of arr` lookahead at line 946.
        uint saved_pos = self.lexer.pos;
        uint saved_line = self.lexer.line;
        uint saved_col = self.lexer.col;
        Token saved_cur = self.lexer.current;
        Token saved_look = self.lexer.lookahead;
        bool saved_haslk = self.lexer.has_lookahead;
        Token saved_push = self.lexer.pushed_back;
        bool saved_haspb = self.lexer.has_pushed_back;
        bool saved_slt = self.lexer.seen_line_term;
        uint saved_pbc = self.pushback_count;
        Token[4] saved_pbs = self.pushback_stack;

        self.advance()!; // consume '[' or '{'
        uint depth = 1;
        while (depth > 0) {
            Token? next_opt = self.lexer.next_token();
            if (try next = next_opt) {
                if (next.type == TokenType.LBRACKET || next.type == TokenType.LBRACE) {
                    depth++;
                } else if (next.type == TokenType.RBRACKET || next.type == TokenType.RBRACE) {
                    depth--;
                } else if (next.type == TokenType.EOF_TOKEN) {
                    break;
                }
            } else {
                break;
            }
        }

        Token? peek_tok = self.lexer.peek();
        if (try pt = peek_tok) {
            if (token_is_of(pt)) {
                is_bare_destr = true;
                bare_is_of = true;
            } else if (pt.type == TokenType.IN) {
                is_bare_destr = true;
                bare_is_of = false;
            }
        }

        // Restore lexer state
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.col = saved_col;
        self.lexer.current = saved_cur;
        self.lexer.lookahead = saved_look;
        self.lexer.has_lookahead = saved_haslk;
        self.lexer.pushed_back = saved_push;
        self.lexer.has_pushed_back = saved_haspb;
        self.lexer.seen_line_term = saved_slt;
        self.pushback_count = saved_pbc;
        self.pushback_stack = saved_pbs;

        if (is_bare_destr) {
            bool is_array_pattern = (next_tt == TokenType.LBRACKET);
            // Bare form: bindings are VAR-scoped, no PUSH_LEX/POP_LEX per iteration.
            if (bare_is_of) {
                self.emit_bare_forof_destruct_loop(is_array_pattern, saved_scope, saved_reg, for_is_await)!;
            } else {
                if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
                self.emit_bare_forin_destruct_loop(is_array_pattern, saved_scope, saved_reg)!;
            }
            return;
        }
    }

    // Parse init (may be var/let/const or expression or empty)
    if (next_tt == TokenType.VAR || next_tt == TokenType.LET || next_tt == TokenType.CONST) {
        // Check if it's for-in: "var x in ..."
        // We parse the variable declaration keyword
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
        ScopeKind decl_kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

        // Check for destructuring: [pattern] or {pattern}
        TokenType after_decl = self.peek_type();
        if (after_decl == TokenType.LBRACKET || after_decl == TokenType.LBRACE) {
            // Check if this is a for-of or for-in with destructuring
            // We need to look ahead past the pattern to see if 'of' or 'in' follows
            bool is_forof_destr = false;
            bool is_forin_destr = false;

            // Save lexer state to look ahead
            uint saved_pos = self.lexer.pos;
            uint saved_line = self.lexer.line;
            uint saved_col = self.lexer.col;
            Token saved_cur = self.lexer.current;
            Token saved_look = self.lexer.lookahead;
            bool saved_haslk = self.lexer.has_lookahead;
            Token saved_push = self.lexer.pushed_back;
            bool saved_haspb = self.lexer.has_pushed_back;
            bool saved_slt = self.lexer.seen_line_term;

            // Skip past the pattern tokens to find 'of' or 'in'
            self.advance()!; // consume '[' or '{'
            uint depth = 1;
            while (depth > 0) {
                Token? next_opt = self.lexer.next_token();
                if (try next = next_opt) {
                    if (next.type == TokenType.LBRACKET || next.type == TokenType.LBRACE) {
                        depth++;
                    } else if (next.type == TokenType.RBRACKET || next.type == TokenType.RBRACE) {
                        depth--;
                    } else if (next.type == TokenType.EOF_TOKEN) {
                        break;
                    }
                } else {
                    break;
                }
            }

            // Now check what follows the pattern
            Token? peek_tok = self.lexer.peek();
            if (try pt = peek_tok) {
                if (token_is_of(pt)) {
                    is_forof_destr = true;
                } else if (pt.type == TokenType.IN) {
                    is_forin_destr = true;
                }
            }

            // Restore lexer state
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.col = saved_col;
            self.lexer.current = saved_cur;
            self.lexer.lookahead = saved_look;
            self.lexer.has_lookahead = saved_haslk;
            self.lexer.pushed_back = saved_push;
            self.lexer.has_pushed_back = saved_haspb;
            self.lexer.seen_line_term = saved_slt;

            if (is_forof_destr) {
                // for (let [a, b] of arr) or for (let {x, y} of arr)
                bool is_array_pattern = (after_decl == TokenType.LBRACKET);
                ushort iter_reg = 0;

                // Parse the destructuring pattern inline.
                // We parse bindings here and emit iterator-based extraction
                // into the loop body below, avoiding lexer state issues with
                // destructure_for_value (which can't re-parse after the header
                // has been consumed).

                DestructBind[MAX_DESTRUCT_BINDS] dbinds;
                ushort[MAX_DESTRUCT_BINDS] dgroup_regs;
                ushort[MAX_DESTRUCT_BINDS] dbinding_regs;
                uint bind_count = 0;
                for (uint i = 0; i < MAX_DESTRUCT_BINDS; i++) { dgroup_regs[i] = 0xFFFF; dbinding_regs[i] = 0xFFFF; }

                // Parse the pattern into the shared DestructBind model, then
                // declare each leaf binding in the loop's scope. The extraction
                // itself is emitted per-iteration in the loop body below.
                // The collectors consume their closing ']' / '}' themselves; the
                // caller consumes only the opening bracket.
                self.advance()!; // consume '[' or '{'
                if (is_array_pattern) {
                    self.collect_arr_param_binds(dbinds[..], &bind_count, 0, 0xFFFF)!;
                } else {
                    self.collect_obj_param_binds(dbinds[..], &bind_count, 0, 0xFFFF)!;
                }
                // A `let`/`const` ForDeclaration's BoundNames must be unique
                // (§14.7.5.1). A `var` head is exempt: the repeated names all
                // denote the same var binding.
                if (is_lexical) {
                    self.check_pattern_bound_names_unique(dbinds[..], bind_count)!;
                }
                for (uint i = 0; i < bind_count; i++) {
                    if (dbinds[i].is_synthetic) continue;
                    HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
                    self.check_var_lex_conflict(hs.get_data(), decl_kind)!;
                    ushort dreg = self.declare_binding_var(hs.get_data(), decl_kind);
                    dbinding_regs[i] = dreg;
                }

                // Consume "of" (contextual keyword - lexed as IDENTIFIER)
                {
                    Token of_tok = self.expect(TokenType.IDENTIFIER)!;
                    if (!token_is_of(of_tok)) {
                        return COMPILE_ERROR~;
                    }
                }

                // TDZ scope for the head bindings (§13.7.5.12).
                // Before evaluating the RHS expression, a TDZ environment is
                // created for the ForDeclaration names so that any reference
                // to them inside the RHS throws a ReferenceError.
                bool has_head_tdz = is_lexical && bind_count > 0;
                if (has_head_tdz) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                    for (uint i = 0; i < bind_count; i++) {
                        if (dbinds[i].is_synthetic) continue;
                        HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
                        char[] bname = hs.get_data();
                        uint name_idx = self.add_string_constant(bname);
                        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
                        // Mark outer scope entry as captured so the compiler
                        // emits GETVAR instead of LDREG, prevents bypassing
                        // the TDZ sentinel in the new lex_env.
                        for (uint j = 0; j < saved_scope; j++) {
                            if (str_eq(self.scope_stack[j].name, bname)) {
                                self.scope_stack[j].is_captured = true;
                                self.has_captured_local = true;
                                break;
                            }
                        }
                    }
                }

                iter_reg = self.assignment_expr()!;

                // Pop the TDZ scope, the head binding references are now
                // resolved against the outer scope for the iterator protocol.
                if (has_head_tdz) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }

                self.expect(TokenType.RPAREN)!;

                ForOfHead head;
                head.kind = DESTRUCTURE;
                head.binds = dbinds[..];
                head.bind_count = bind_count;
                head.group_regs = dgroup_regs[..];
                head.binding_regs = dbinding_regs[..];
                head.store_mode = DestructStoreMode.DECLARE;
                head.is_array_pattern = is_array_pattern;
                head.is_lexical = is_lexical;
                head.is_const = is_const;
                self.emit_forof(head, iter_reg, saved_scope, saved_reg, for_is_await)!;
                return;
            } else if (is_forin_destr) {
                if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
                // for-in with destructuring: for (let {x, y} in obj) or for (let [a, b] in obj)
                bool is_array_pattern = (after_decl == TokenType.LBRACKET);
                ushort obj_reg = 0;

                // Collect the pattern with the shared param collectors.
                DestructBind[MAX_DESTRUCT_BINDS] fdbinds;
                uint fdcount = 0;
                self.advance()!; // consume '[' or '{'
                if (is_array_pattern) {
                    self.collect_arr_param_binds(fdbinds[..], &fdcount, 0, 0xFFFF)!;
                } else {
                    self.collect_obj_param_binds(fdbinds[..], &fdcount, 0, 0xFFFF)!;
                }
                // §14.7.5.1, as for the for-of head above.
                if (is_lexical) {
                    self.check_pattern_bound_names_unique(fdbinds[..], fdcount)!;
                }
                ushort[MAX_DESTRUCT_BINDS] fdgroup_regs;
                ushort[MAX_DESTRUCT_BINDS] fdbinding_regs;
                uint[MAX_DESTRUCT_BINDS] fd_periter_name_idxs;
                bool[MAX_DESTRUCT_BINDS] fd_periter_is_const;
                uint fd_periter_count = 0;
                bool fd_needs_periter = false;
                for (uint i = 0; i < fdcount; i++) { fdgroup_regs[i] = 0xFFFF; fdbinding_regs[i] = 0xFFFF; }
                for (uint i = 0; i < fdcount; i++) {
                    if (fdbinds[i].is_synthetic) continue;
                    HString* hs = (HString*)self.constants[fdbinds[i].name_idx].get_heapptr();
                    self.check_var_lex_conflict(hs.get_data(), decl_kind)!;
                    fdbinding_regs[i] = self.declare_binding_var(hs.get_data(), decl_kind);
                    if (is_lexical && self.is_captured_name(hs.get_data())) {
                        fd_periter_name_idxs[fd_periter_count] = fdbinds[i].name_idx;
                        fd_periter_is_const[fd_periter_count] = is_const;
                        fd_periter_count++;
                        fd_needs_periter = true;
                    }
                }

                self.expect(TokenType.IN)!;
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                    for (uint i = 0; i < fdcount; i++) {
                        if (fdbinds[i].is_synthetic) continue;
                        HString* hs = (HString*)self.constants[fdbinds[i].name_idx].get_heapptr();
                        self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(hs.get_data()));
                    }
                }
                obj_reg = self.expression()!;
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                }
                self.expect(TokenType.RPAREN)!;

                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                ushort key_reg = self.alloc_reg();
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)key_reg, (uint)has_next, (uint)iter_state);

                // Exit before destructuring: on the terminating NEXTFOR the key
                // register is stale (undefined) and must not be destructured.
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                // Destructure each enumerated key via the shared emitter.
                if (!is_array_pattern) {
                    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)key_reg, 0, 0);
                }
                for (uint bi = 0; bi < fdcount; bi++) {
                    if (fdbinds[bi].parent_idx == 0xFFFF) fdbinds[bi].arg_idx = key_reg;
                }
                if (fdcount > 0) {
                    self.emit_destruct_bindings(fdbinds[..], fdcount, fdgroup_regs[..], fdbinding_regs[..],
                                                DestructStoreMode.DECLARE, is_lexical, is_const);
                }

                // The head's `)` closes the for-in clause, not an operand, so a
                // following `/` must start a RegularExpressionLiteral (B2).
                self.lexer.note_block_close();
                self.statement_body()!;

                // CreatePerIterationEnvironment.  Copy all leaf bindings before
                // replacing the current environment so closures from this body
                // retain the values for this iteration.
                uint cycle_label = self.code_count;
                if (fd_needs_periter) {
                    self.emit_create_per_iteration_env(fd_periter_name_idxs[..],
                                                       fd_periter_is_const[..], fd_periter_count);
                }
                self.loop_stack[self.loop_depth - 1].continue_target = cycle_label;

                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth -= 2;
                }

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            } else {
                if (for_is_await) return self.fail("'for await' requires a 'for await (... of ...)' head")~;
                // Standard for-loop with destructuring init: for (var [a,b] = ...; ...; ...)
                // A lexical head owns one environment for the whole loop.  The
                // destructuring helpers emit PUTLEX/PUTLEX_C while evaluating the
                // initializer, so install that environment before they run (the
                // common exit path below emits the matching POP_LEX).
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                }
                if (after_decl == TokenType.LBRACKET) {
                    self.advance()!; // consume '['
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    self.advance()!; // consume '{'
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                }

                // More declarations? (var [a]=x, b=y)
                while (self.match(TokenType.COMMA)) {
                    TokenType nt = self.peek_type();
                    if (nt == TokenType.LBRACKET) {
                        self.advance()!;
                        self.array_destructure(decl_kind, is_lexical, is_const)!;
                    } else if (nt == TokenType.LBRACE) {
                        self.advance()!;
                        self.object_destructure(decl_kind, is_lexical, is_const)!;
                    } else {
                        Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                        // Intern now: escaped identifier borrows the lexer's
                        // shared ident_buf scratch, which the initializer
                        // expression will overwrite. declare_var stores this
                        // slice into scope_stack, which outlives this token.
                        char[] extra_name2 = ((Heap*)self.heap).str_intern(extra_name.str_value).get_data();
                        self.check_var_lex_conflict(extra_name2, decl_kind)!;
                        self.try_skip_ts_type_annotation()!;
                        ushort extra_reg = self.declare_var(extra_name2, decl_kind);
                        if (self.match(TokenType.ASSIGN)) {
                            ushort extra_val = self.assignment_expr()!;
                            if (extra_val != extra_reg) {
                                self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                            }
                            self.free_reg(extra_val);
                        } else {
                            self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                        }
                        uint extra_name_idx = self.add_string_constant(extra_name2);
                        self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                    }
                }

                self.expect(TokenType.SEMICOLON)!;
            }
        } else {
            // A `for (var|let|const X ...)` head binds a BindingIdentifier, so
            // the §13.1.1 restricted names are rejected here exactly as they
            // are for a plain `var X` declaration.
            Token name_tok = self.expect_binding_identifier()!;
            // Intern now: an escaped for-head binding name borrows the
            // lexer's shared ident_buf scratch, which the head's RHS
            // expression and the loop body parsed below will overwrite.
            // declare_var stores this slice into scope_stack, which
            // outlives the current token.
            name_tok.str_value = ((Heap*)self.heap).str_intern(name_tok.str_value).get_data();
            self.try_skip_ts_type_annotation()!;

            // Check for "in" (for-in) or "of" (for-of)
            if (self.peek_type() == TokenType.IN) {
                if (for_is_await) return self.fail("'for await' requires 'of', not 'in'")~;
                // for (let/const/var x in obj) { ... }
                self.advance()!;  // consume 'in'
                // ForIn/OfHeadEvaluation creates the lexical head environment
                // before evaluating the RHS. The binding must therefore be in
                // TDZ while the object expression is evaluated.
                // Ensure a register-cached outer binding cannot bypass the TDZ
                // environment while compiling the RHS.
                if (is_lexical) {
                    for (uint j = 0; j < saved_scope; j++) {
                        if (str_eq(self.scope_stack[j].name, name_tok.str_value)) {
                            self.scope_stack[j].is_captured = true;
                            self.has_captured_local = true;
                            break;
                        }
                    }
                }
                self.check_var_lex_conflict(name_tok.str_value, decl_kind)!;
                ushort iter_var = self.declare_binding_var(name_tok.str_value, decl_kind);
                if (is_lexical) {
                    // Mark the freshly-declared iter-var entry as captured                    // and force its reads through the env (resolves_var →
                    // SCOPE_ERROR → GETVAR).  The matching has_captured_local
                    // flip is required so the register-resident-locals
                    // elision in CompilerContext.finish() does NOT NOP the
                    // per-iteration PUTLEX/INITTZ below, NOP'ing them
                    // leaves the env without the binding and the body's
                    // GETVAR throws "p is not defined" (regression fixed
                    // when this flag was set here but the elide gate missed
                    // it).  Mirrors the outer-scope walk above, which sets
                    // both flags together.
                    self.scope_stack[self.scope_depth - 1].is_captured = true;
                    self.has_captured_local = true;
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                    self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(name_tok.str_value));
                }
                ushort obj_reg = self.expression()!;
                // Keep the head TDZ environment alive for closures created by
                // the RHS, while the loop gets a distinct binding environment.
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                }
                self.expect(TokenType.RPAREN)!;

                // The head TDZ environment is retained beneath the initial
                bool needs_forin_periter = is_lexical
                    && self.is_captured_name(name_tok.str_value);
                // The TDZ environment above remains active for the first iteration.
                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                // NEXTFOR lands the key in a SCRATCH register, never straight in
                // the binding register: the exhausting step reports has_next=false
                // and writes undefined to its A operand, which would clobber the
                // binding with undefined on the way out of the loop (a `var` head's
                // binding is readable after the loop, so that is observable). The
                // key moves into the binding only past the exhaustion branch, the
                // same shape emit_bare_forin_loop uses.
                ushort key_slot = self.alloc_reg();
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)key_slot, (uint)has_next, (uint)iter_state);

                // A completed NEXTFOR does not perform BindingInitialization.
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                self.emit_abc(Opcode.LDREG, (uint)iter_var, (uint)key_slot, 0);

                // Store the current key in the active per-iteration environment.
                uint forin_name_idx = self.add_string_constant(name_tok.str_value);
                self.emit_var_store(iter_var, forin_name_idx, is_lexical, is_const);

                // Compile body. Each body evaluation starts with an empty
                // completion; an expression statement then replaces it.
                if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
                // The head's `)` closes the for-in clause, not an operand, so a
                // following `/` must start a RegularExpressionLiteral (B2).
                self.lexer.note_block_close();
                self.statement_body()!;

                // CreatePerIterationEnvironment: copy the current binding into a
                // fresh environment before the next NEXTFOR.  Closures created
                // in this body therefore retain this iteration's environment.
                uint cycle_label = self.code_count;
                if (needs_forin_periter) {
                    uint[1] cycle_name_idxs;
                    bool[1] cycle_is_const;
                    cycle_name_idxs[0] = forin_name_idx;
                    cycle_is_const[0] = is_const;
                    self.emit_create_per_iteration_env(cycle_name_idxs[..], cycle_is_const[..], 1);
                }
                self.loop_stack[self.loop_depth - 1].continue_target = cycle_label;

                // Jump back to loop start
                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                // Pop the final iteration environment and the retained head TDZ
                // environment. Earlier iteration environments remain alive when
                // captured by loop closures.
                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth -= 2;
                }

                self.free_reg(key_slot);
                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            }
            // Check for "of" (for-of), contextual keyword, not a reserved word
            if (try tok = self.lexer.peek()) {
                if (token_is_of(tok)) {
                    self.advance()!;  // consume "of"
                    // TDZ scope for the head binding (§13.7.5.12).
                    // Before evaluating the RHS, a TDZ environment is created
                    // for the head name so that typeof/name access inside the
                    // RHS throws ReferenceError (temporal dead zone).
                    if (is_lexical) {
                        self.emit_simple(Opcode.PUSH_LEX);
                        self.cur_lex_depth++;
                        self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(name_tok.str_value));
                        // Mark the outer scope entry as captured so the compiler
                        // emits GETVAR instead of LDREG, without this, a
                        // register-cached value from an outer scope would bypass
                        // the TDZ sentinel in the new lex_env.
                        for (uint j = 0; j < saved_scope; j++) {
                            if (str_eq(self.scope_stack[j].name, name_tok.str_value)) {
                                self.scope_stack[j].is_captured = true;
                                self.has_captured_local = true;
                                break;
                            }
                        }
                    }
                    ushort iter_reg = self.assignment_expr()!;
                    // Pop the TDZ scope after RHS evaluation.
                    if (is_lexical) {
                        self.emit_simple(Opcode.POP_LEX);
                        self.cur_lex_depth--;
                    }
                    self.expect(TokenType.RPAREN)!;
                    uint name_idx = self.add_string_constant(name_tok.str_value);
                    self.emit_forof_loop(name_tok.str_value, iter_reg, saved_scope, saved_reg, is_lexical, is_const, false, for_is_await)!;
                    return;
                }
            }

            // Standard for loop: we already consumed the decl keyword and identifier
            if (for_is_await) return self.fail("'for await' requires a 'for await (... of ...)' head")~;
            // Declare the variable and optionally initialize
            self.check_var_lex_conflict(name_tok.str_value, decl_kind)!;
            ushort var_reg;
            if (!is_lexical) {
                // Capture-blind lookup: a captured var must be detected as
                // already declared (see the var_declaration redecl note).
                ushort? existing = self.find_local_reg(name_tok.str_value);
                if (try er = existing) {
                    var_reg = er;
                } else {
                    var_reg = self.declare_var(name_tok.str_value, decl_kind);
                }
            } else {
                var_reg = self.declare_var(name_tok.str_value, decl_kind);
            }
            // Captured loop vars are env-resident: the condition/update
            // compile to GETVAR/INC_VAR and the env is authoritative, so the
            // register-cache sync machinery (which would write the stale
            // register copy back over the env) must stay off.
            //
            // resolve_var additionally gates register-caching on the binding
            // having a live scope entry. The scope stack is heap-grown now, so
            // a missing entry means an allocation failure (recorded as
            // scope_overflow, which aborts the compile) rather than the silent
            // skip this originally guarded against — but the check below is
            // kept because it is the same condition either way: a name with no
            // scope entry reads through the env and its register is never
            // updated, so has_for_var must be false or the sync writes a stale
            // register back over the env every iteration.
            has_for_var = !is_lexical && !self.is_global
                       && !self.is_captured_name(name_tok.str_value);
            if (has_for_var) {
                ushort? for_var_rslv = self.resolve_var(name_tok.str_value);
                if (catch _fault = for_var_rslv) {
                    has_for_var = false;
                }
            }
            for_var_reg = var_reg;
            for_var_name_idx = self.add_string_constant(name_tok.str_value);
            // Collect per-iter binding: a let/const binding needs a fresh env each
            // iteration so closures in different iterations capture distinct values.
            // Only captured bindings trigger per-iter; the pre_scan_captures pass
            // runs for both function and global scope now.
            if (is_lexical && self.is_captured_name(name_tok.str_value)) {
                needs_periterenv = true;
            }
            if (is_lexical && periterenv_count < 8) {
                periterenv_names[periterenv_count] = name_tok.str_value;
                periterenv_name_idxs[periterenv_count] = for_var_name_idx;
                periterenv_is_const[periterenv_count] = is_const;
                periterenv_count++;
            }
            if (is_lexical) { self.emit_simple(Opcode.PUSH_LEX); self.cur_lex_depth++; }
            if (self.match(TokenType.ASSIGN)) {
                // §14.7.4: a C-style for head declares
                // `VariableDeclarationList[~In]` / `LexicalDeclaration[~In]`,
                // so a declarator's Initializer is `[~In]` as well —
                // `for (var x = 1 in {};;)` is a SyntaxError, not a for-in
                // head. Parenthesizing (`= (1 in {})`) restores `[+In]`.
                self.forbid_in = true;
                ushort init_val = self.assignment_expr()!;
                self.forbid_in = false;
                if (init_val != var_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)var_reg, (uint)init_val, 0);
                }
                self.free_reg(init_val);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
            }
            // Also store in environment (needed at global scope for GETVAR)
            self.emit_var_store(var_reg, for_var_name_idx, is_lexical, is_const);

            // More declarations?
            while (self.match(TokenType.COMMA)) {
                TokenType nt2 = self.peek_type();
                if (nt2 == TokenType.LBRACKET) {
                    self.advance()!;
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else if (nt2 == TokenType.LBRACE) {
                    self.advance()!;
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                    // Intern now: escaped identifier borrows the lexer's
                    // shared ident_buf scratch, which the initializer
                    // expression and later declarators/body will overwrite.
                    // declare_var stores this slice into scope_stack, which
                    // outlives this token.
                    char[] extra_name2 = ((Heap*)self.heap).str_intern(extra_name.str_value).get_data();
                    self.check_var_lex_conflict(extra_name2, decl_kind)!;
                    self.try_skip_ts_type_annotation()!;
                    ushort extra_reg;
                    if (!is_lexical) {
                        ushort? existing2 = self.resolve_var(extra_name2);
                        if (try er2 = existing2) {
                            extra_reg = er2;
                        } else {
                            extra_reg = self.declare_var(extra_name2, decl_kind);
                        }
                    } else {
                        extra_reg = self.declare_var(extra_name2, decl_kind);
                    }
                    if (self.match(TokenType.ASSIGN)) {
                        // `[~In]`, as for the first declarator above.
                        self.forbid_in = true;
                        ushort extra_val = self.assignment_expr()!;
                        self.forbid_in = false;
                        if (extra_val != extra_reg) {
                            self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                        }
                        self.free_reg(extra_val);
                    } else {
                        self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                    }
                    uint extra_name_idx = self.add_string_constant(extra_name2);
                    self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                    // Track extra let/const bindings for per-iter env prologue.
                    if (is_lexical && self.is_captured_name(extra_name2)) {
                        needs_periterenv = true;
                    }
                    if (is_lexical && periterenv_count < 8) {
                        periterenv_names[periterenv_count] = extra_name2;
                        periterenv_name_idxs[periterenv_count] = extra_name_idx;
                        periterenv_is_const[periterenv_count] = is_const;
                        periterenv_count++;
                    }
                }
            }

            self.expect(TokenType.SEMICOLON)!;
        }
    } else if (next_tt != TokenType.SEMICOLON) {
        // Expression init (C-style for), no async form.
        if (for_is_await) return self.fail("'for await' requires a 'for await (... of ...)' head")~;
        // §14.7.4: the head is `Expression[~In]`, so a top-level `in` here is
        // a SyntaxError rather than being read as a for-in head that then
        // fails on the `;`.
        ushort init_reg = self.expression_no_in()!;
        self.free_reg(init_reg);
        // Guard: if the init expression returned a local variable's register
        // (e.g. `i = 0` returning `i`'s reg), free_reg may have dropped
        // next_reg below the locals already allocated before the for-statement.
        // Restore next_reg to saved_reg so subsequent alloc_reg calls do not
        // clobber those live locals.
        if (self.next_reg < saved_reg) {
            self.next_reg = saved_reg;
        }
        self.expect(TokenType.SEMICOLON)!;
    } else {
        // Empty init (C-style `for (;;)`), no async form.
        if (for_is_await) return self.fail("'for await' requires a 'for await (... of ...)' head")~;
        self.expect(TokenType.SEMICOLON)!;
    }

    // Register floor for the re-compiled condition and increment. Lexical
    // (let/const) for-init variables stay live in registers allocated ABOVE
    // saved_reg for the whole loop, so the condition/increment temporaries must
    // allocate above them, not at saved_reg, which sits below the loop var and
    // would let e.g. the GETPROP key of `i < obj.length` clobber `i`.
    ushort cond_floor = self.next_reg;
    if (cond_floor < saved_reg) cond_floor = saved_reg;

    // --- Rotated for-loop layout ---
    // Avoid running the condition before the first body iteration by rotating:
    //
    //   JUMP → cond_label            (executed once; provides zero-iteration check)
    //   body_label:
    //     <body>
    //   incr_label:                  ← continue targets here
    //     <increment>
    //   cond_label:
    //     <condition>  (IF_TRUE → body_label , back edge)
    //   exit:                        ← break patches here
    //
    // With the JMP_LT/JMP_LE/JMP_GT/JMP_GE peephole, the per-iteration hot path
    // is: body → increment → LT + IF_TRUE → JMP_LT body_label ≈4 dispatches.
    //
    // Literal hoisting: for the common condition `<ident> <relop> <numeric literal>`,
    // we pre-load the literal into a pinned register before the initial JUMP.
    // This removes LDINT/LDCONST from the per-iteration hot path.
    //
    // Implementation: we save the lexer state at the condition and increment,
    // use a token-scanner (skip_expr_lex) to skip them without emitting code,
    // compile the body at body_label, then restore+compile increment at incr_label,
    // then restore+compile condition at cond_label with IF_TRUE → body_label.

    // ----------------------------------------------------------------
    // Step 0: Detect simple condition: IDENTIFIER <relop> NUMBER ;
    // ----------------------------------------------------------------

    uint  _cond_pos; uint  _cond_line; uint  _cond_col;
    Token _cond_cur; Token _cond_look; bool  _cond_haslk;
    Token _cond_push; bool _cond_haspb; bool _cond_slt;
    uint  _cond_pbc;  Token[4] _cond_pbs;
    _cond_pos   = self.lexer.pos;
    _cond_line  = self.lexer.line;
    _cond_col   = self.lexer.col;
    _cond_cur   = self.lexer.current;
    _cond_look  = self.lexer.lookahead;
    _cond_haslk = self.lexer.has_lookahead;
    _cond_push  = self.lexer.pushed_back;
    _cond_haspb = self.lexer.has_pushed_back;
    _cond_slt   = self.lexer.seen_line_term;
    _cond_pbc   = self.pushback_count;
    _cond_pbs   = self.pushback_stack;

    bool has_cond = !self.check(TokenType.SEMICOLON);

    // Detect `IDENTIFIER <relop> NUMBER ;` (only when pushback is empty)
    bool has_simple_cond = false;
    double simple_cond_rhs = 0.0;
    Opcode simple_cond_op = Opcode.LT;
    ushort pinned_rhs_reg = 0;

    // Use the captured state (_cond_haslk / _cond_haspb) rather than the current lexer
    // state: self.check() above calls lexer.peek() which sets has_lookahead as a side
    // effect, so testing self.lexer.has_lookahead here always returns true (false negative).
    if (has_cond && _cond_pbc == 0 && !_cond_haspb && !_cond_haslk) {
        Token? t1o = self.lexer.next_token();
        if (try t1 = t1o) {
            Token? t2o = self.lexer.next_token();
            if (try t2 = t2o) {
                Token? t3o = self.lexer.next_token();
                if (try t3 = t3o) {
                    Token? t4o = self.lexer.next_token();
                    if (try t4 = t4o) {
                        bool is_ident = (t1.type == TokenType.IDENTIFIER);
                        bool is_relop = (t2.type == TokenType.LT || t2.type == TokenType.LE
                                      || t2.type == TokenType.GT || t2.type == TokenType.GE);
                        bool is_num   = (t3.type == TokenType.NUMBER);
                        bool is_semi  = (t4.type == TokenType.SEMICOLON);
                        if (is_ident && is_relop && is_num && is_semi) {
                            has_simple_cond = true;
                            simple_cond_rhs = t3.num_value;
                            switch (t2.type) {
                                case TokenType.LT: simple_cond_op = Opcode.LT;
                                case TokenType.LE: simple_cond_op = Opcode.LE;
                                case TokenType.GT: simple_cond_op = Opcode.GT;
                                default:           simple_cond_op = Opcode.GE;
                            }
                        }
                    }
                }
            }
        }
        // Restore to before detection scan.
        self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
        self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
        self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
        self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
        self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
    }

    // ----------------------------------------------------------------
    // Step 1: Pre-load the pinned RHS register (before initial JUMP).
    // ----------------------------------------------------------------
    if (has_simple_cond) {
        pinned_rhs_reg = self.alloc_reg();
        int int_rhs = (int)simple_cond_rhs;
        if ((double)int_rhs == simple_cond_rhs
            && int_rhs >= bytecode::MIN_SBC && int_rhs <= bytecode::MAX_SBC) {
            self.emit_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs);
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx);
        }
    }

    // ForBodyEvaluation performs CreatePerIterationEnvironment once before
    // the first test/body evaluation, as well as after every completed body.
    // This separates closures created by the head initializer from closures
    // created by the test and first body iteration.
    if (needs_periterenv) {
        self.emit_create_per_iteration_env(
            periterenv_name_idxs[..], periterenv_is_const[..], periterenv_count);
    }

    // ----------------------------------------------------------------
    // Step 2: Emit initial JUMP → cond_label and record body_label.
    // ----------------------------------------------------------------
    // ES6 §13.7.4.8: ForBodyEvaluation starts with V=undefined. In eval mode,
    // reset eval_acc_reg once before the loop so an empty or never-iterated
    // loop returns undefined per the spec.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    uint cond_jump = 0;
    bool has_empty_cond = !has_cond;
    if (!has_empty_cond) {
        cond_jump = self.emit_jump(Opcode.JUMP);  // forward → cond_label
    }
    uint body_label = self.code_count;

    // ----------------------------------------------------------------
    // Step 3: Skip condition tokens (no code emitted) using token scanner.
    // ----------------------------------------------------------------
    if (has_cond) {
        // skip_expr_lex scans until `;` or `)` at depth 0, leaving the terminator
        // in the lexer's pushed_back buffer.
        self.skip_expr_lex();
    }
    self.expect(TokenType.SEMICOLON)!;  // consume the `;` after condition

    // ----------------------------------------------------------------
    // Step 4: Save lexer state for increment, then skip it.
    // ----------------------------------------------------------------
    uint  _incr_pos; uint  _incr_line; uint  _incr_col;
    Token _incr_cur; Token _incr_look; bool  _incr_haslk;
    Token _incr_push; bool _incr_haspb; bool _incr_slt;
    uint  _incr_pbc;  Token[4] _incr_pbs;
    _incr_pos   = self.lexer.pos;   _incr_line  = self.lexer.line;   _incr_col   = self.lexer.col;
    _incr_cur   = self.lexer.current; _incr_look  = self.lexer.lookahead;
    _incr_haslk = self.lexer.has_lookahead; _incr_push  = self.lexer.pushed_back;
    _incr_haspb = self.lexer.has_pushed_back; _incr_slt = self.lexer.seen_line_term;
    _incr_pbc   = self.pushback_count; _incr_pbs   = self.pushback_stack;

    bool has_incr = !self.check(TokenType.RPAREN);
    if (has_incr) {
        self.skip_expr_lex();
    }
    self.expect(TokenType.RPAREN)!;   // consume `)` after increment
    // The `)` just consumed closes the for-clause, not an operand, so a
    // following `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();

    // ----------------------------------------------------------------
    // Step 5: Push loop and compile body.
    // ----------------------------------------------------------------
    // continue_target placeholder = body_label; updated to incr_label after body.
    self.push_loop(body_label, true);

    // ES6 §13.7.4.8 ForBodyEvaluation: in eval mode, reset eval_acc_reg to
    // undefined at the top of the body each iteration. This matches the
    // expected behavior for test262 cases like
    // `for/head-init-var-check-empty-inc-empty-completion.js` where a
    // break inside the body should leave eval_acc_reg at undefined, not the
    // value of the previous iteration's last expression statement.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    self.statement_body()!;

    // Save the lexer state after the body, this is where the outer parser
    // must resume after for_statement returns.  Steps 6 and 7 will restore
    // lexer state for re-compilation; we restore to here at the very end.
    uint  _post_pos; uint  _post_line; uint  _post_col;
    Token _post_cur; Token _post_look; bool  _post_haslk;
    Token _post_push; bool _post_haspb; bool _post_slt;
    uint  _post_pbc;  Token[4] _post_pbs;
    _post_pos   = self.lexer.pos;   _post_line  = self.lexer.line;   _post_col   = self.lexer.col;
    _post_cur   = self.lexer.current; _post_look  = self.lexer.lookahead;
    _post_haslk = self.lexer.has_lookahead; _post_push  = self.lexer.pushed_back;
    _post_haspb = self.lexer.has_pushed_back; _post_slt = self.lexer.seen_line_term;
    _post_pbc   = self.pushback_count; _post_pbs   = self.pushback_stack;

    // ----------------------------------------------------------------
    // Step 6: incr_label, CreatePerIterationEnvironment, then compile increment.
    // ----------------------------------------------------------------
    // Per-iteration environment (ES2015 §14.7.4.2 CreatePerIterationEnvironment):
    // The spec runs CreatePerIterationEnvironment *after* the body and *before*
    // the increment on every iteration (ForBodyEvaluation step 3.e). We emit the
    // env-cycling code here at incr_label so that `continue` also triggers it,
    // keeping the semantics correct: GETVAR reads the binding's current value (the
    // env is authoritative, INC_VAR and PUTVAR both update it), then POP_LEX/
    // PUSH_LEX/PUTLEX installs that value into a fresh env. The increment then runs
    // in the fresh env, and the next body iteration will read the updated value
    // from that same env through its captured reference.
    uint incr_label = self.code_count;
    if (needs_periterenv) {
        self.emit_create_per_iteration_env(
            periterenv_name_idxs[..], periterenv_is_const[..], periterenv_count);
    }
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = incr_label;
    }

    if (has_incr) {
        self.lexer.pos = _incr_pos; self.lexer.line = _incr_line; self.lexer.col = _incr_col;
        self.lexer.current = _incr_cur; self.lexer.lookahead = _incr_look;
        self.lexer.has_lookahead = _incr_haslk; self.lexer.pushed_back = _incr_push;
        self.lexer.has_pushed_back = _incr_haspb; self.lexer.seen_line_term = _incr_slt;
        self.pushback_count = _incr_pbc; self.pushback_stack = _incr_pbs;
        // The loop body may have dropped next_reg below the for-statement's
        // high-water mark (e.g. expression_statement frees the result register
        // of an assignment whose target is the topmost live local).  Restore to
        // cond_floor so the increment and condition compile into fresh temporaries
        // above all live locals (including the lexical loop var), not into
        // registers that belong to live variables.
        if (self.next_reg < cond_floor) {
            self.next_reg = cond_floor;
        }
        // The update clause's value is discarded (see free_reg below), signal
        // the void context so a plain assignment skips its result-preservation
        // moves.
        self.void_ctx = true;
        self.postfix_void = true;
        ushort incr_reg = self.expression()!;
        bool incr_is_local = self.last_was_local_var && self.last_local_var_reg == incr_reg;
        self.void_ctx = false;
        self.postfix_void = false;
        // `++i` on a let/const binding returns the binding's home register;
        // freeing it would pop next_reg below the live local (see the switch
        // discriminant guard above).
        if (!incr_is_local) {
            self.free_reg(incr_reg);
        }
    }

    // Sync register-cached for-init var back to the environment when necessary.
    // Closures/direct-eval inside the loop can observe the binding each iteration,
    // so keep it up to date. Otherwise the variable lives purely in its register
    // for the loop's duration, which avoids the expensive PUTVAR/GETVAR pair.
    bool for_var_needs_iter_sync = has_for_var && (self.has_closures || self.has_direct_eval);
    if (for_var_needs_iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }

    // ----------------------------------------------------------------
    // Step 7: cond_label, patch initial JUMP, compile condition with IF_TRUE back edge.
    // ----------------------------------------------------------------
    if (!has_empty_cond) {
        self.patch_jump(cond_jump);
    }

    if (!has_empty_cond) {
        if (has_simple_cond) {
            // Re-compile condition from saved lexer state, using pinned_rhs_reg.
            self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
            self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
            self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
            self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
            self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
            Token ident_tok = self.advance()!;
            Token _relop    = self.advance()!;  // consume relop
            Token _num_tok  = self.advance()!;  // consume NUMBER (value already in pinned_rhs_reg)
            self.expect(TokenType.SEMICOLON)!;  // consume `;`

            ushort lhs_reg = self.alloc_reg();
            // Mirror primary_expr: at global scope the identifier is read from the
            // environment (registers are not kept in sync with the env by the body),
            // via emit_ident_read so a proven primitive-only global gets the
            // guard-free GETGLOBAL_PRIM instead of a guarded GETVAR. This read runs
            // every iteration, so it was the one place the prim-slot proof was
            // being skipped on the hottest top-level shape. resolve_var is only safe
            // when the body also uses the register directly (non-global scope).
            if (!self.is_global) {
                if (try reg = self.resolve_var(ident_tok.str_value)) {
                    if (reg != lhs_reg) {
                        self.emit_abc(Opcode.LDREG, (uint)lhs_reg, (uint)reg, 0);
                    }
                } else {
                    uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                    self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
                }
            } else {
                uint name_idx2 = self.add_string_constant(ident_tok.str_value);
                self.emit_ident_read((uint)lhs_reg, name_idx2);
            }
            ushort cmp_res = self.alloc_reg();
            self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
            self.free_reg(lhs_reg);
            self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cmp_res, body_label);
            self.free_reg(cmp_res);
            self.free_reg(pinned_rhs_reg);
        } else {
            // General condition: restore and re-compile normally.
            self.lexer.pos = _cond_pos; self.lexer.line = _cond_line; self.lexer.col = _cond_col;
            self.lexer.current = _cond_cur; self.lexer.lookahead = _cond_look;
            self.lexer.has_lookahead = _cond_haslk; self.lexer.pushed_back = _cond_push;
            self.lexer.has_pushed_back = _cond_haspb; self.lexer.seen_line_term = _cond_slt;
            self.pushback_count = _cond_pbc; self.pushback_stack = _cond_pbs;
            // Compile condition temporaries above all live locals.  The body may
            // have lowered next_reg (freeing the result register of a top-of-stack
            // assignment), which would otherwise let the condition allocate into a
            // register still owned by a live variable such as the for-init var
            // (cond_floor sits above any lexical loop variable).
            if (self.next_reg < cond_floor) {
                self.next_reg = cond_floor;
            }
            ushort cond_reg = self.expression()!;
            self.expect(TokenType.SEMICOLON)!;
            self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cond_reg, body_label);
            self.free_expr_reg(cond_reg);
        }
    } else {
        // for(;;), unconditional back edge
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, back));
    }

    // exit: pop_loop patches all break jumps to current position.
    self.pop_loop();
    if (is_lexical) { self.emit_simple(Opcode.POP_LEX); self.cur_lex_depth--; }

    // For uncaptured for-init vars the environment was not updated each
    // iteration, so write the final register value once before the register
    // is freed and subsequent code reads the binding via GETVAR.
    if (has_for_var && !for_var_needs_iter_sync) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)for_var_reg, for_var_name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)for_var_reg, for_var_name_idx);
    }

    // Restore the lexer to the position after the body so the outer parser
    // continues from the right source position.
    self.lexer.pos = _post_pos; self.lexer.line = _post_line; self.lexer.col = _post_col;
    self.lexer.current = _post_cur; self.lexer.lookahead = _post_look;
    self.lexer.has_lookahead = _post_haslk; self.lexer.pushed_back = _post_push;
    self.lexer.has_pushed_back = _post_haspb; self.lexer.seen_line_term = _post_slt;
    self.pushback_count = _post_pbc; self.pushback_stack = _post_pbs;

    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// Capture the full lexer + compiler-pushback state for later replay
// via restore_lhs_snapshot. See ForLhsSnapshot for why this must be
// the whole state, not just a byte offset.
fn ForLhsSnapshot CompilerContext.save_lhs_snapshot(&self) {
    ForLhsSnapshot s;
    s.pos    = self.lexer.pos;
    s.line   = self.lexer.line;
    s.col    = self.lexer.col;
    s.cur    = self.lexer.current;
    s.look   = self.lexer.lookahead;
    s.haslk  = self.lexer.has_lookahead;
    s.push   = self.lexer.pushed_back;
    s.haspb  = self.lexer.has_pushed_back;
    s.slt    = self.lexer.seen_line_term;
    s.pbc    = self.pushback_count;
    s.pbs    = self.pushback_stack;
    return s;
}

// Restore a snapshot captured by save_lhs_snapshot.
fn void CompilerContext.restore_lhs_snapshot(&self, ForLhsSnapshot s) {
    self.lexer.pos             = s.pos;
    self.lexer.line            = s.line;
    self.lexer.col             = s.col;
    self.lexer.current         = s.cur;
    self.lexer.lookahead       = s.look;
    self.lexer.has_lookahead   = s.haslk;
    self.lexer.pushed_back     = s.push;
    self.lexer.has_pushed_back = s.haspb;
    self.lexer.seen_line_term  = s.slt;
    self.pushback_count        = s.pbc;
    self.pushback_stack        = s.pbs;
}

// Drop the compiler side effects of a for-in/of member head parse whose
// code has just been rewound. member_expr() leaves behind state that later
// expressions consult as if it described the most recent instruction:
//
//  - call_prop_obj_reg records the receiver of a method call. A discarded
//    `o.p` head leaves it set, which makes the next call in the function
//    take the method-call path: `undef_this` is false, so the callee's
//    speculatively stripped GETVAR/GETGLOBAL is never restored and the call
//    dispatches on a register nothing ever wrote ("X is not a function").
//  - last_was_getvar/last_was_getglobal anchor the CALL_VAR/CALL_GLOBAL
//    fusion to `last_getvar_code_pos + 1 == code_count`. After a rewind that
//    equality can hold for an unrelated instruction.
fn void CompilerContext.discard_member_head_state(&self) {
    self.call_prop_obj_reg = REG_NONE;
    self.last_was_getvar = false;
    self.last_was_getglobal = false;
}

// Emit a bare for-in loop whose LHS is a plain identifier with no
// declaration keyword: `for (x in obj) { ... }`. Mirrors the
// `var`/`let`/`const` for-in path but stores each key via PUTVAR
// against an existing binding instead of declaring a new one.
fn void? CompilerContext.emit_bare_forin_loop(&self, char[] var_name, ushort obj_reg, uint saved_scope, ushort saved_reg) {
    uint name_idx = self.add_string_constant(var_name);
    ushort iter_var = self.alloc_reg();
    // Bare `for (b in ...)` assigns to an existing binding: the head is an
    // assignment position, not a declaration. If the target is a register-cached
    // local, publish the key straight into its home register so the body's
    // register read sees it (PUTVAR alone updates only the env slot and then
    // clears the source, desyncing the local — same hazard the bare for-of path
    // handles in emit_head_bind).
    ushort home_reg = REG_NONE;
    if (!self.is_global) {
        if (try home = self.resolve_var(var_name)) { home_reg = home; }
    }

    ushort iter_state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);

    // The store must follow the exhaustion test: the final NEXTFOR reports
    // has_next=false and leaves iter_var undefined, so storing before the branch
    // would clobber the target with undefined after the last real key (and, for
    // an undeclared target, would throw on an empty object, which is legal).
    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);

    if (home_reg != REG_NONE) {
        self.emit_abc(Opcode.LDREG, (uint)home_reg, (uint)iter_var, 0);
    } else {
        // PUTVAR_ASSIGN, not PUTVAR: an undeclared target must throw
        // ReferenceError rather than create an implicit global (strict-only),
        // and a const/TDZ target must throw like any other assignment.
        self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)iter_var, name_idx);
    }

    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    // The head's `)` closes the for-in clause, not an operand, so a following
    // `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();
    self.statement_body()!;

    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    self.free_reg(iter_state);
    self.free_reg(obj_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// ============================================================================
// Unified for-of codegen: one skeleton drives every for-of form, with ForOfHead
// selecting the per-value step, which binds an identifier, destructures, or
// stores to a member. `is_await` selects the sync or async iterator protocol.
// ============================================================================

// Iterator record produced by emit_iter_open and threaded through the loop.
struct IterRec {
    ushort method_reg;  // the iterator object (also the ITER_CLOSE target)
    ushort next_reg;    // its .next method
    ushort callee_reg;  // per-iteration callee slot (reloaded each step)
    ushort callee_this_reg;
    bool   is_await;
    // Address of the fused fast path's done-branch, valid while
    // has_fast_exit. Lives here rather than on the context because for-of
    // loops nest: a shared field would be overwritten by the inner loop and
    // the outer branch would never be patched, leaving it jumping to offset
    // zero -- an infinite loop.
    uint   fast_exit;
    bool   has_fast_exit;
}

// GetIterator(src, hint): look up the iterator method, call it, fetch .next.
// For sync (hint=sync) this is Symbol.iterator. For async (hint=async,
// for-await) this is GET_ITER_ASYNC, which does the spec GetIterator(obj,async):
// prefer Symbol.asyncIterator; if absent, wrap Symbol.iterator() in an
// %AsyncFromSyncIterator% adapter so a plain sync iterable (array, generator)
// works under `for await`. Either way the iterator lands in method_reg (below
// the callee window) and .next in next_reg, with the callee/this window ABOVE
// them, so a generator source overlaying the sliding window on resume cannot
// clobber them (see plan 042/043).
fn IterRec? CompilerContext.emit_iter_open(&self, ushort src_reg, bool is_await) {
    ushort method_reg;
    if (is_await) {
        // GET_ITER_ASYNC A, B: A ← GetIterator(reg B, async). Handles the
        // @@asyncIterator lookup + AsyncFromSync wrapping in one VM step, so the
        // iterator object lands directly in method_reg (allocated first → below
        // the callee window, same invariant as the sync path's CALL result).
        method_reg = self.alloc_reg();
        self.emit_abc(Opcode.GET_ITER_ASYNC, (uint)method_reg, (uint)src_reg, 0);
    } else {
        // A null/undefined source is not iterable; reject it before the
        // @@iterator read, which would otherwise fail as a property access.
        self.emit_abc(Opcode.CHKITER, (uint)src_reg, 0, 1);

        ushort sym_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));
        ushort iter_key_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);
        ushort symbol_val_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
        self.free_reg(iter_key_reg);
        self.free_reg(sym_reg);

        method_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)src_reg, (uint)symbol_val_reg);
        self.free_reg(symbol_val_reg);

        // GetIterator step 3, before the call: a non-callable @@iterator must
        // report that the source is not iterable, not that undefined is not a
        // function (which the bare CALL below would say).
        self.emit_abc(Opcode.CHKITER, (uint)method_reg, (uint)src_reg, 0);

        ushort this_slot = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)src_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
        self.free_reg(this_slot);

        // GetIterator step 5: the iterator the method returned must be an
        // Object, checked before the `.next` read below.
        self.emit_abc(Opcode.CHKITER, (uint)method_reg, 0, 2);
    }

    ushort next_reg = self.alloc_reg();
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);

    IterRec rec;
    rec.method_reg = method_reg;
    rec.next_reg = next_reg;
    rec.callee_reg = self.alloc_reg();
    rec.callee_this_reg = self.alloc_reg();
    rec.is_await = is_await;
    return rec;
}

// One iteration step: reload callee/this (healing a generator source that
// overwrote the callee window last iteration), call .next(), require an object
// result, unpack .done/.value. Writes the value into val_slot (which the caller
// allocated below the callee window) and returns the exit jump to patch at the
// done=true target. Leaves no live temps above val_slot.
fn uint? CompilerContext.emit_iter_step(&self, IterRec rec, ushort val_slot, uint* out_fast_exit) {
    // Fused fast step for a built-in array iterator, laid out as the opcode
    // documents: refusal falls through to the first JUMP (into the generic
    // sequence below), a finished iteration takes the second, and a produced
    // value lands past both. for-await is excluded because its step has to
    // await the promise .next() returns.
    uint fast_done_jump = 0;
    uint fast_cont_jump = 0;
    bool has_fast = false;
    *out_fast_exit = 0;
    if (!rec.is_await) {
        self.emit_abc(Opcode.ITER_NEXT_FAST, (uint)val_slot, (uint)rec.method_reg, (uint)rec.next_reg);
        // Layout the handler relies on, in the order it branches to them:
        //   +0  JUMP -> the generic sequence (refusal falls through to here)
        //   +1  JUMP -> the loop exit        (handled, iteration finished)
        //   +2  JUMP -> the loop body        (handled, value produced)
        // The third is needed because the generic sequence sits between this
        // point and the body: landing "past the JUMPs" would land on the slow
        // path, not on the consumer of the value.
        uint to_slow = self.emit_jump(Opcode.JUMP);
        fast_done_jump = self.emit_jump(Opcode.JUMP);
        fast_cont_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(to_slow);
        has_fast = true;
    }

    self.emit_abc(Opcode.LDREG, (uint)rec.callee_reg, (uint)rec.next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)rec.callee_this_reg, (uint)rec.method_reg, 0);

    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)rec.callee_reg, 0);

    // for-await (§14.7.5.6): the async .next() returns a Promise of the
    // IteratorResult, await it, then treat the settled value as the result.
    // GET_ITER_ASYNC guarantees a genuine async iterator (sync sources are
    // adapter-wrapped, and the adapter awaits the value internally), so a single
    // await here suffices; the settled result is a plain {value, done} object.
    if (rec.is_await) {
        self.emit_abc(Opcode.AWAIT, (uint)result_reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, (uint)result_reg, 0, 0);
    }

    // ES2022 §14.7.5.6 step 3.b: the .next() result must be an Object.
    self.emit_abc(Opcode.CHKOBJ, (uint)result_reg, 0, 0);

    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    ushort value_key_reg = self.alloc_reg();
    ushort val_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

    // Move the value below the callee window, then release the above-window
    // protocol temps so the per-value consumer (which may run a nested iterator
    // protocol for destructuring) does not overlap the outer call frame.
    self.emit_abc(Opcode.LDREG, (uint)val_slot, (uint)val_reg, 0);
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // Both the fast path's done-branch and the generic path's done-branch have
    // to reach the same loop exit. Chain the fast one onto the generic one so
    // the single returned jump still describes the exit for the caller to
    // patch; the fast branch lands on the generic branch, which then jumps on.
    if (has_fast) {
        // The continue-branch lands here, where the generic path arrives once
        // it has stored the value. The done-branch cannot be aimed at the
        // generic done-branch itself -- that is an IF_TRUE reading a register
        // only the generic path fills -- so it is returned to the caller
        // alongside exit_jump and patched to the same loop exit.
        self.patch_jump(fast_cont_jump);
        *out_fast_exit = fast_done_jump;
    }

    return exit_jump;
}

// IteratorClose on the loop iterator. throw_variant=true suppresses errors from
// .return access/call (the original throw takes precedence, §7.4.6 steps 6,8).
// For for-await this is AsyncIteratorClose (§7.4.11): the .return() result is
// awaited before the completion propagates.
fn void CompilerContext.emit_iter_close(&self, IterRec rec, bool throw_variant) {
    if (rec.is_await) {
        // ITER_CLOSE_ASYNC leaves the .return() result in method_reg (or
        // undefined when there is nothing to close) and reports whether a
        // real result needs awaiting in did_await_reg. §7.4.11 only calls
        // Await when .return() was actually invoked, unlike a real user
        // `await`, AWAIT always costs a microtask tick now, so the no-close
        // case must skip it entirely rather than "awaiting undefined".
        ushort did_await_reg = self.alloc_reg();
        self.emit_abc(Opcode.ITER_CLOSE_ASYNC, (uint)rec.method_reg, throw_variant ? 1 : 0, (uint)did_await_reg);
        uint skip_await = self.emit_cond_jump(Opcode.IF_FALSE, (uint)did_await_reg);
        self.emit_abc(Opcode.AWAIT, (uint)rec.method_reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, (uint)rec.method_reg, 0, 0);
        self.patch_jump(skip_await);
        self.free_reg(did_await_reg);
        return;
    }
    self.emit_abc(Opcode.ITER_CLOSE, (uint)rec.method_reg, throw_variant ? 1 : 0, 0);
}

// Free the four iterator-record registers (reverse allocation order).
fn void CompilerContext.free_iter_rec(&self, IterRec rec) {
    self.free_reg(rec.callee_this_reg);
    self.free_reg(rec.callee_reg);
    self.free_reg(rec.next_reg);
    self.free_reg(rec.method_reg);
}

// The single for-of loop skeleton. The RHS has already been evaluated into
// src_reg; head describes the per-iteration value binding. On entry the loop
// variable / pattern (per head) is already declared in the current scope.
// Emits the full ForIn/OfBodyEvaluation loop (§14.7.5.6): GetIterator → loop
// { per-iter env, .next, done? exit, bind, body } → IteratorClose. Frees
// src_reg and restores scope/regs to saved_scope/saved_reg on exit.
fn void? CompilerContext.emit_forof(&self, ForOfHead head, ushort src_reg, uint saved_scope, ushort saved_reg, bool is_await) {
    IterRec rec = self.emit_iter_open(src_reg, is_await)!;

    // Value lives below the callee window for the whole loop, so a nested
    // iterator protocol (destructuring) never overlaps the outer call frame.
    ushort val_slot = self.alloc_persistent_reg();

    // ES §14.7.5.6: V starts as undefined; reset the eval accumulator so a
    // zero-iteration loop yields undefined (identifier form, eval mode only).
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);
    self.loop_stack[self.loop_depth - 1].iter_close_reg = (int)rec.method_reg;
    self.loop_stack[self.loop_depth - 1].is_await_loop = is_await;

    // Per-iteration lexical environment (§14.7.5.6 CreatePerIterationEnvironment):
    // fresh declarative env each iteration so body closures capture distinct
    // bindings. INITTZ marks each head binding TDZ before the value is stored.
    bool needs_per_iter_env = head.is_lexical && !head.id_is_bare;
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
        self.emit_head_inittz(head);
    }

    uint fast_exit = 0;
    uint exit_jump = self.emit_iter_step(rec, val_slot, &fast_exit)!;

    // IteratorClose-on-throw guard (§14.7.5.6): wrapping the bind and body means
    // any abrupt completion closes the iterator before propagating.
    uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

    self.emit_head_bind(head, val_slot)!;

    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }
    // The head's `)` closes the for-of clause, not an operand, so a following
    // `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();
    self.statement_body()!;

    self.emit_simple(Opcode.ENDTRY);
    uint jump_over = self.emit_jump(Opcode.JUMP);

    uint catch_target = self.code_count;
    ushort err_reg = self.alloc_reg();
    self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.emit_iter_close(rec, true);
    self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
    self.free_reg(err_reg);

    self.patch_jump(jump_over);
    uint catch_off = catch_target - iter_try_addr;
    self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
    self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

    // Normal-path per-iter env epilogue (continue already popped its own env
    // back to the loop level, so it lands on the back-jump, not here).
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }

    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    // Exit path (done=true): pop the per-iter env. Per ES2022 §14.7.5.7
    // ForIn/OfBodyEvaluation, a `nextResult.[[Done]]` of true ends the loop
    // with a normal completion directly, IteratorClose/AsyncIteratorClose
    // is only invoked for an abrupt completion out of the loop (break,
    // throw, or a `return` inside the body), never on natural exhaustion.
    self.patch_jump(exit_jump);
    // The fused fast path's done-branch exits the loop at the same point.
    if (fast_exit != 0) { self.patch_jump(fast_exit); }
    if (needs_per_iter_env) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.pop_loop();

    self.free_reg(val_slot);
    self.free_iter_rec(rec);
    self.free_reg(src_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// Per-iteration TDZ init for lexical head bindings (fresh env each iteration).
fn void CompilerContext.emit_head_inittz(&self, ForOfHead head) {
    switch (head.kind) {
        case IDENT:
            self.emit_a_bc(Opcode.INITTZ, 0, head.id_name_idx);
        case DESTRUCTURE:
            for (uint i = 0; i < head.bind_count; i++) {
                if (head.binds[i].is_synthetic) continue;
                HString* hs = (HString*)self.constants[head.binds[i].name_idx].get_heapptr();
                uint name_idx = self.add_string_constant(hs.get_data());
                self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
            }
        case MEMBER:
            // no head bindings
    }
}

// The per-value step: bind val_slot to the loop target (§14.7.5.6). Runs inside
// the IteratorClose-on-throw guard.
fn void? CompilerContext.emit_head_bind(&self, ForOfHead head, ushort val_slot) {
    switch (head.kind) {
        case IDENT:
            if (head.id_is_bare && head.id_reg_resident) {
                // Register-cached local target: write straight into its home
                // register (id_reg). No PUTVAR, that would update only the env
                // slot and then clear the source reg, leaving the body's register
                // read of the local stale (bare-forof var-desync fix). Matches how
                // a plain `b = val` assignment to a register-resident local emits.
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
            } else if (head.id_is_bare) {
                // Env-resident bare target: stage in id_reg, then store to the env.
                // PUTVAR_ASSIGN, not PUTVAR: the head is an assignment position, so
                // an undeclared target must throw ReferenceError instead of creating
                // an implicit global (strict-only), and const/TDZ must throw too.
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
                self.emit_a_bc(Opcode.PUTVAR_ASSIGN, (uint)head.id_reg, head.id_name_idx);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)head.id_reg, (uint)val_slot, 0);
                self.emit_var_store(head.id_reg, head.id_name_idx, head.is_lexical, head.is_const);
            }
        case DESTRUCTURE:
            // Object patterns reject null/undefined even when empty.
            if (!head.is_array_pattern) {
                self.emit_abc(Opcode.REQUIRE_OBJ, (uint)val_slot, 0, 0);
            }
            for (uint bi = 0; bi < head.bind_count; bi++) {
                if (head.binds[bi].parent_idx == 0xFFFF) head.binds[bi].arg_idx = val_slot;
            }
            if (head.bind_count > 0) {
                self.emit_destruct_bindings(head.binds, head.bind_count, head.group_regs,
                    head.binding_regs, head.store_mode, head.is_lexical, head.is_const);
            } else if (head.is_array_pattern) {
                // Empty array pattern `for ([] of e)`: still GetIterator+close.
                self.emit_empty_array_iter(val_slot);
            }
        case MEMBER:
            self.emit_member_lhs_store(head.lhs_snap, val_slot)!;
    }
}

// Emit a for-of loop with a bare destructuring pattern LHS:
// `for ([a, b] of arr) { ... }` or `for ({x, y} of arr) { ... }`.
// Bindings are VAR-scoped and persist across iterations (no per-iter
// block scope). The '[' or '{' has NOT been consumed on entry.
fn void? CompilerContext.emit_bare_forof_destruct_loop(&self, bool is_array_pattern, uint saved_scope, ushort saved_reg, bool is_await = false) {
    // Collect the assignment pattern with the shared collectors.
    // Bare for-of (`for ([a] of ...)` / `for ({x} of ...)`) assigns to existing
    // lvalues, so this uses the assignment collectors (full LHS grammar) and
    // emits via emit_destruct_bindings(ASSIGN_TARGET), one algorithm shared
    // with array/object destructuring assignment.
    //
    // The pattern's default values are AssignmentExpressions (ES2022
    // §13.15.5.2/§13.15.5.3), so the in_formal_params gate on await/yield in
    // compile_default_expr must not apply while collecting (see
    // array_destructure_assign).
    bool saved_in_fp = self.in_formal_params;
    self.in_formal_params = false;
    defer self.in_formal_params = saved_in_fp;

    DestructBind[MAX_DESTRUCT_BINDS] dbinds;
    uint dcount = 0;
    self.advance()!; // consume '[' or '{'
    if (is_array_pattern) {
        self.collect_arr_assign_binds(dbinds[..], &dcount)!;
    } else {
        self.collect_obj_assign_binds(dbinds[..], &dcount)!;
    }

    ushort[MAX_DESTRUCT_BINDS] dgroup_regs;
    ushort[MAX_DESTRUCT_BINDS] dbinding_regs;
    for (uint i = 0; i < dcount; i++) { dgroup_regs[i] = 0xFFFF; dbinding_regs[i] = 0xFFFF; }
    // Allocate a binding register per leaf: member targets and unresolvable
    // identifiers get a fresh temp; resolvable locals reuse their slot.
    for (uint i = 0; i < dcount; i++) {
        if (dbinds[i].is_synthetic) continue;
        if (dbinds[i].is_member_target) { dbinding_regs[i] = self.alloc_reg(); continue; }
        HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
        char[] name = hs.get_data();
        if (!self.is_global) {
            if (try existing = self.resolve_var(name)) { dbinding_regs[i] = existing; continue; }
        }
        // Env-resident target: temp + forced PUTVAR so const-assignment throws.
        dbinding_regs[i] = self.alloc_reg();
        dbinds[i].assign_needs_putvar = true;
    }

    // Consume "of" (lexed as IDENTIFIER)
    {
        Token of_tok = self.expect(TokenType.IDENTIFIER)!;
        if (!token_is_of(of_tok)) {
            return COMPILE_ERROR~;
        }
    }

    ushort iter_reg = self.assignment_expr()!;
    self.expect(TokenType.RPAREN)!;

    // Bare assignment pattern: VAR-scoped (no per-iter env), ASSIGN_TARGET store.
    ForOfHead head;
    head.kind = DESTRUCTURE;
    head.binds = dbinds[..];
    head.bind_count = dcount;
    head.group_regs = dgroup_regs[..];
    head.binding_regs = dbinding_regs[..];
    head.store_mode = DestructStoreMode.ASSIGN_TARGET;
    head.is_array_pattern = is_array_pattern;
    head.is_lexical = false;
    head.is_const = false;
    self.emit_forof(head, iter_reg, saved_scope, saved_reg, is_await)!;
}

// Emit a for-in loop with a bare destructuring pattern LHS:
// `for ([a, b] in obj) { ... }` or `for ({x, y} in obj) { ... }`.
// The '[' or '{' has NOT been consumed.
fn void? CompilerContext.emit_bare_forin_destruct_loop(&self, bool is_array_pattern, uint saved_scope, ushort saved_reg) {
    // A bare pattern in a for-in head is an AssignmentPattern (ES2024
    // §14.7.5.1, same as the for-of form): it assigns to existing lvalues
    // rather than declaring, so member-expression targets like
    // `for ({length: obj.p} in o)` are legal and the restricted-name early
    // errors (`yield`, `eval`, `arguments`) apply to its identifier leaves.
    // Use the assignment collectors and the ASSIGN_TARGET store mode, exactly
    // as emit_bare_forof_destruct_loop does.
    //
    // The pattern's default values are AssignmentExpressions, not
    // FormalParameter defaults, so the in_formal_params await/yield gate must
    // not apply while collecting (see array_destructure_assign).
    bool saved_in_fp = self.in_formal_params;
    self.in_formal_params = false;
    defer self.in_formal_params = saved_in_fp;

    DestructBind[MAX_DESTRUCT_BINDS] dbinds;
    uint dcount = 0;
    self.advance()!; // consume '[' or '{'
    if (is_array_pattern) {
        self.collect_arr_assign_binds(dbinds[..], &dcount)!;
    } else {
        self.collect_obj_assign_binds(dbinds[..], &dcount)!;
    }
    ushort[MAX_DESTRUCT_BINDS] dgroup_regs;
    ushort[MAX_DESTRUCT_BINDS] dbinding_regs;
    for (uint i = 0; i < dcount; i++) { dgroup_regs[i] = 0xFFFF; dbinding_regs[i] = 0xFFFF; }
    // Allocate a binding register per leaf: member targets and unresolvable
    // identifiers get a fresh temp; resolvable locals reuse their slot.
    for (uint i = 0; i < dcount; i++) {
        if (dbinds[i].is_synthetic) continue;
        if (dbinds[i].is_member_target) { dbinding_regs[i] = self.alloc_reg(); continue; }
        HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
        char[] name = hs.get_data();
        if (!self.is_global) {
            if (try existing = self.resolve_var(name)) { dbinding_regs[i] = existing; continue; }
        }
        // Env-resident target: temp + forced PUTVAR so const-assignment throws.
        dbinding_regs[i] = self.alloc_reg();
        dbinds[i].assign_needs_putvar = true;
    }

    self.expect(TokenType.IN)!;
    ushort obj_reg = self.expression()!;
    self.expect(TokenType.RPAREN)!;


    ushort iter_state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    ushort key_reg = self.alloc_reg();
    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)key_reg, (uint)has_next, (uint)iter_state);

    // Exit before destructuring: on the terminating NEXTFOR, key_reg is stale
    // (undefined), so the pattern extraction must not run for it.
    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);

    // Destructure each enumerated key via the shared emitter. The head is an
    // AssignmentPattern, so the leaves store through ASSIGN_TARGET.
    if (!is_array_pattern) {
        self.emit_abc(Opcode.REQUIRE_OBJ, (uint)key_reg, 0, 0);
    }
    for (uint bi = 0; bi < dcount; bi++) {
        if (dbinds[bi].parent_idx == 0xFFFF) dbinds[bi].arg_idx = key_reg;
    }
    if (dcount > 0) {
        self.emit_destruct_bindings(dbinds[..], dcount, dgroup_regs[..], dbinding_regs[..],
                                    DestructStoreMode.ASSIGN_TARGET, false, false);
    }

    // The head's `)` closes the for-in clause, not an operand, so a following
    // `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();
    self.statement_body()!;

    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    self.free_reg(iter_state);
    self.free_reg(obj_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// Emit a for-of loop whose head LHS is a member expression, e.g.
// `for (obj.prop of arr) { ... }` (ES2015 §13.7.5.1: the head's
// AssignmentExpression may be any valid assignment target, not just
// an identifier). The LHS is re-parsed from source and re-compiled
// fresh at the top of every iteration (right before the body), which
// gives correct per-iteration re-evaluation of the member base per
// spec, reusing the same PUTPROP path normal assignment uses.
fn void? CompilerContext.emit_forof_loop_member(&self, ForLhsSnapshot lhs_snap, ushort iter_reg, uint saved_scope, ushort saved_reg, bool is_await = false) {
    ForOfHead head;
    head.kind = MEMBER;
    head.lhs_snap = lhs_snap;
    self.emit_forof(head, iter_reg, saved_scope, saved_reg, is_await)!;
}

// Emit a for-in loop whose head LHS is a member expression, e.g.
// `for (obj.prop in x) { ... }`. Same re-parse-per-iteration strategy
// as emit_forof_loop_member.
fn void? CompilerContext.emit_forin_loop_member(&self, ForLhsSnapshot lhs_snap, ushort obj_reg, uint saved_scope, ushort saved_reg) {
    ushort key_reg = self.alloc_reg();

    ushort iter_state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)key_reg, (uint)has_next, (uint)iter_state);

    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);

    self.emit_member_lhs_store(lhs_snap, key_reg)!;

    if (self.eval_mode) self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    // The head's `)` closes the for-in clause, not an operand, so a following
    // `/` must start a RegularExpressionLiteral (B2).
    self.lexer.note_block_close();
    self.statement_body()!;

    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    self.free_reg(iter_state);
    self.free_reg(key_reg);
    self.free_reg(obj_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// Re-parse a member-expression LHS from a saved lexer snapshot and
// emit `<lhs> = val_reg` via PUTPROP. Used by the for-of/for-in
// member-LHS loops to re-evaluate the assignment target fresh each
// iteration (ES2015 §13.7.5.13 ForIn/OfBodyEvaluation: the reference
// is (re-)resolved every iteration for non-declaration LHS forms).
fn void? CompilerContext.emit_member_lhs_store(&self, ForLhsSnapshot lhs_snap, ushort val_reg) {
    ForLhsSnapshot resume_snap = self.save_lhs_snapshot();

    self.restore_lhs_snapshot(lhs_snap);

    ushort mreg = self.member_expr()!;
    if (self.last_was_member()) {
        self.free_reg(mreg);
        self.emit_abc(Opcode.PUTPROP, (uint)self.member_obj(), (uint)self.member_prop(), (uint)val_reg);
        self.free_reg(self.member_prop());
        self.free_reg(self.member_obj());
    }

    self.restore_lhs_snapshot(resume_snap);
    // The re-parsed head is a store target, never a call receiver: clear the
    // state it left so the code following the loop is not compiled as though
    // a method call were in progress.
    self.discard_member_head_state();
}

// Parse do-while statement.
fn void? CompilerContext.do_while_statement(&self) {
    self.expect(TokenType.DO)!;

    // ES spec §14.7.2.2: do-while starts with V=undefined. In eval mode, reset
    // eval_acc_reg at the top of each iteration (loop_start is the back-edge
    // target, so the reset runs on every pass). An empty body or break with no
    // preceding expression leaves eval_acc_reg as undefined.
    uint loop_start = self.code_count;
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Continue target is the condition (we'll record the address after the body)
    self.push_loop(loop_start, true);  // temporary; we'll fix continue_target

    // Compile body
    self.statement_body()!;

    // Fix the continue target to point to the condition
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    }

    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.match(TokenType.SEMICOLON);

    // If condition is true, jump back to loop_start
    self.emit_cond_jump_back(Opcode.IF_TRUE, (uint)cond_reg, loop_start);
    self.free_expr_reg(cond_reg);

    self.pop_loop();
}

// Emit the non-throw IteratorClose for the loop at loop_stack[li] during an
// abrupt-exit unwind (break/return/labeled break). For a for-await loop this is
// AsyncIteratorClose (§7.4.11): the .return() result must be awaited. Clobbering
// the iterator register with the awaited result is safe here, the loop is being
// abandoned. Assumes loop_stack[li].iter_close_reg >= 0.
fn void CompilerContext.emit_unwind_iter_close(&self, uint li) {
    uint reg = (uint)self.loop_stack[li].iter_close_reg;
    // Pop the loop body's IteratorClose-on-throw catcher (the TRY emitted
    // around bind+body). Jumping out of the body bypasses its ENDTRY, which
    // left that catcher on act.cat: harmless where the next pop happens to
    // belong to it, but an ENDFINALLY reached afterwards then pops the stale
    // for-of catcher instead of the finally's own and drops the completion it
    // was carrying -- `try { throw e } finally { for (v of it) break; }` lost
    // `e` entirely.
    self.emit_simple(Opcode.ENDTRY);
    if (self.loop_stack[li].is_await_loop) {
        self.emit_abc(Opcode.ITER_CLOSE_ASYNC, reg, 0, 0);
        self.emit_abc(Opcode.AWAIT, reg, 0, 0);
        self.emit_abc(Opcode.LOAD_RESUME, reg, 0, 0);
    } else {
        self.emit_abc(Opcode.ITER_CLOSE, reg, 0, 0);
    }
}

// Parse return statement.
// Emit ITER_CLOSE for every enclosing for-of loop, innermost first.
// A return exits all loops in the function, so each loop's iterator must be
// closed (§14.7.5.7, abrupt loop completions call IteratorClose).
fn void CompilerContext.emit_return_iter_closes(&self) {
    for (int li = (int)self.loop_depth - 1; li >= 0; li--) {
        if (self.loop_stack[li].iter_close_reg >= 0) {
            self.emit_unwind_iter_close((uint)li);
        }
    }
}

fn void? CompilerContext.return_statement(&self) {
    self.expect(TokenType.RETURN)!;

    // ES2015 §14.9.1: `return` is only valid inside a FunctionBody, a
    // top-level Script or eval-code Program has no function to return from.
    // A nested function body gets its own CompilerContext (is_global always
    // false there), so this only fires for genuinely top-level `return`.
    if (self.is_global) {
        self.record_error("return is not allowed outside a function");
        return COMPILE_ERROR~;
    }

    // ES2022 §15.7.11: a class static block's own StatementList is
    // ClassStaticBlockStatementList[~Return], `return` at this level is a
    // SyntaxError (a nested function/method declared inside the block is
    // its own CompilerContext with forbid_return left false, so it may
    // still return from itself).
    if (self.forbid_return) {
        return self.fail("return is not allowed in class static block")~;
    }

    // Check if there's a return value (not a semicolon or end-of-statement)
    // A line terminator between return and the expression causes ASI (ES5 §12.9)
    TokenType next = self.peek_type();
    if (next == TokenType.SEMICOLON || next == TokenType.RBRACE ||
        next == TokenType.EOF_TOKEN || self.lexer.seen_line_term) {
        self.emit_return_iter_closes();
        self.emit_simple(self.is_user_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    } else {
        ushort val_reg = self.expression()!;
        // §13.10.1 ReturnStatement step 3: inside an async generator, a
        // `return Expression;` awaits the value before completing (one tick).
        // `return;` (RETUNDEF above) and normal fall-off-end do NOT await.
        if (self.is_async && self.is_user_generator) {
            self.emit_abc(Opcode.AWAIT, (uint)val_reg, 0, 0);
            self.emit_abc(Opcode.LOAD_RESUME, (uint)val_reg, 0, 0);
        }
        // IteratorClose runs after the return value is evaluated but before
        // the frame unwinds (§14.7.5.7 loop completion propagation).
        self.emit_return_iter_closes();
        self.emit_abc(self.is_user_generator ? Opcode.RET_GEN : Opcode.RET, (uint)val_reg, 0, 0);
        // Note: do NOT free_reg(val_reg) here.  The return value register may
        // be a live local variable (e.g. `return i` inside a for-loop body).
        // Calling free_reg would let the allocator reuse it for subsequent
        // code (the loop increment/condition), clobbering the variable.
    }

    self.expect_semicolon_or_asi()!;
}

// Parse throw statement.
fn void? CompilerContext.throw_statement(&self) {
    self.expect(TokenType.THROW)!;

    // ES2024 §14.14: `throw [no LineTerminator here] Expression ;`. This is a
    // restricted production, not an ASI opportunity: a line terminator after
    // `throw` is a SyntaxError, there is no `throw;` form to fall back to.
    // Force the lookahead scan before reading seen_line_term, which otherwise
    // still describes the whitespace before `throw` itself.
    self.peek_type();
    if (self.lexer.seen_line_term) {
        return self.fail("no line break is allowed between 'throw' and its expression")~;
    }

    ushort val_reg = self.expression()!;
    self.emit_abc(Opcode.THROW, (uint)val_reg, 0, 0);
    // Note: do NOT free_reg(val_reg) here, same reason as return_statement.

    self.expect_semicolon_or_asi()!;
}

// Parse try/catch/finally statement.
//
// Bytecode layout:
//   TRY A=flags, BC=catch_offset    , A bit0=catch, bit1=finally
//   NOP A=0,    BC=finally_offset   , jump slot (0 if no finally)
//   <try block>
//   ENDTRY
//   JUMP -> finally_or_after
//   [CATCH rX , at try_addr + catch_offset]
//   [<catch block>]
//   [FINALLY  , at try_addr + finally_offset (if has_finally)]
//   [<finally block>]
//   [ENDFINALLY]
fn void? CompilerContext.try_statement(&self) {
    self.expect(TokenType.TRY)!;

    // --- Eval-mode completion value tracking ---
    // ES2015 §13.15.8: for try-finally / try-catch-finally, if the
    // finally block completes normally, the try statement's completion
    // value is the try block's value (B) or the catch block's value (C),
    // NOT the finally block's value (F).  We implement this by:
    //   1. Resetting eval_acc_reg to undefined before the try block
    //      (so an empty try block yields undefined, not a stale value).
    //   2. Saving eval_acc_reg after the try block (captures B).
    //   3. If there's a catch, saving eval_acc_reg after the catch block
    //      (captures C for the exceptional path).
    //   4. Restoring eval_acc_reg after the finally block (before
    //      ENDFINALLY, which handles return/break/continue/throw by
    //      jumping away, so the restore only fires for normal completion).
    ushort try_completion_reg = 0;
    bool eval_try_tracking = false;

    // Emit TRY instruction (placeholder: A=0, BC=0, jump_slot BC=0)
    uint try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
    // Jump slot, the VM reads this word for the finally_offset (BC field)
    uint jump_slot_addr = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Push try info
    if (self.try_depth < MAX_TRY_DEPTH) {
        self.try_stack[self.try_depth].catch_addr = try_addr;
        self.try_stack[self.try_depth].finally_addr = NO_PATCH;
        self.try_depth++;
    }

    // In eval mode, reset eval_acc_reg to undefined so that an empty try
    // block (or one whose body has no expressions) contributes undefined
    // rather than a stale value from a preceding expression statement.
    // We also allocate a temp register to save/restore across the finally
    // block; it's only used when a finally clause is present, but we
    // allocate it unconditionally to avoid a second pass.
    if (self.eval_mode) {
        eval_try_tracking = true;
        try_completion_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Compile try block
    self.block(false)!;

    // In eval mode, save the try block's completion value (B) so the
    // finally block cannot overwrite it.
    if (eval_try_tracking) {
        self.emit_abc(Opcode.LDREG, (uint)try_completion_reg, (uint)self.eval_acc_reg, 0);
    }

    // Emit ENDTRY to pop the try handler (normal exit)
    self.emit_simple(Opcode.ENDTRY);

    // Jump (skips catch handler; target patched later)
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // catch handler starts here
    uint catch_target = self.code_count;

    // Parse catch clause
    bool has_catch = false;
    bool has_finally = false;
    uint finally_tgt = 0;

    if (self.match(TokenType.CATCH)) {
        has_catch = true;
        uint catch_scope = self.scope_depth;
        ushort catch_saved_reg = self.next_reg;
        bool catch_binding_scope = false;

        if (self.match(TokenType.LPAREN)) {
            // Catch parameter, either a plain identifier (ES5) or a
            // destructuring pattern (ES2019 §13.15.1).
            TokenType ct = self.peek_type();
            if (ct == TokenType.LBRACKET || ct == TokenType.LBRACE) {
                // Catch destructuring: catch ([a, b]) or catch ({x, y})
                // Bindings have block scope (LET).  Allocate a temp for
                // the thrown value via CATCH, then extract per-binding.
                self.advance()!; // consume '[' or '{'
                ushort catch_val_reg = self.alloc_reg();
                self.emit_abc(Opcode.CATCH, (uint)catch_val_reg, 0, 0);
                // Catch bindings live in their own lexical scope so they
                // shadow (not clobber) same-named outer bindings. The VM's
                // CATCH handler rebalanced lex_env to the TRY-entry level.
                self.emit_simple(Opcode.PUSH_LEX);
                self.cur_lex_depth++;
                catch_binding_scope = true;

                // Per spec: the thrown value must be object-coercible
                // (null/undefined throws TypeError) for object patterns
                //, even empty `{}` patterns, per ES2019 §13.15.1.5.
                // Array patterns also throw if the value isn't iterable,
                // but iterator-protocol .next() already produces a TypeError
                // for null/undefined via GetMethod's ToObject step.
                if (ct == TokenType.LBRACE) {
                    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)catch_val_reg, 0, 0);
                    self.compile_catch_object_pattern(catch_val_reg)!;
                } else {
                    self.compile_catch_array_pattern(catch_val_reg)!;
                }
                if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                self.expect(TokenType.RPAREN)!;
                self.free_reg(catch_val_reg);
            } else {
                // CatchParameter's BindingIdentifier is [?Yield, ?Await], so
                // `await`/`yield` are valid names where the context permits
                // (e.g. inside a non-async arrow nested in a static block).
                // expect_binding_identifier applies the restricted-name rule
                // to the plain-identifier path only, exactly matching that.
                Token catch_param = self.expect_binding_identifier()!;
                if (self.lexer.ts_mode) self.try_skip_ts_type_annotation()!;
                self.expect(TokenType.RPAREN)!;

                // Marked as a parameter: the catch body's `let`/`const` may not
                // redeclare it (§14.15.1), though a body `var` may.
                ushort catch_var = self.declare_var(catch_param.str_value, VAR, true);
                // Force the catch variable through the environment (GETVAR/PUTVAR)
                // instead of direct register access.  PUTVAR clears the source
                // register after storing to the env (for refcount correctness),
                // so a later register read would get undefined.
                if (!self.is_global && self.scope_depth > 0) {
                    self.scope_stack[self.scope_depth - 1].is_captured = true;
                    self.has_captured_local = true;
                }
                self.emit_abc(Opcode.CATCH, (uint)catch_var, 0, 0);
                // The catch parameter lives in its own lexical scope so it
                // shadows (not clobbers) a same-named outer binding: PUTLEX
                // declares it in the fresh env. Subsequent GETVAR/TYPEOFIDENT
                // resolve it through the environment chain.
                self.emit_simple(Opcode.PUSH_LEX);
                self.cur_lex_depth++;
                catch_binding_scope = true;
                {
                    uint name_idx = self.add_string_constant(catch_param.str_value);
                    self.emit_a_bc(Opcode.PUTLEX, (uint)catch_var, name_idx);
                }
            }
        } else {
            // catch without binding (ES2019)
            ushort discard = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)discard, 0, 0);
            self.free_reg(discard);
        }

        // Compile catch block. It is the CatchParameter's body scope, so a
        // top-level `let`/`const` in it may not redeclare the parameter.
        self.block(false, false, true)!;

        // Close the catch-binding scope on the normal exit path (exceptional
        // exits rebalance via the Catcher's saved lex_env; returns tear down
        // the activation).
        if (catch_binding_scope) {
            self.emit_simple(Opcode.POP_LEX);
            self.cur_lex_depth--;
        }

        self.pop_scope_to(catch_scope);
        self.free_regs_to(catch_saved_reg);

        // In eval mode with a finally clause, save the catch block's
        // completion value (C).  On the exceptional path this overwrites
        // the try block's value saved earlier; on the normal path this
        // instruction is never reached (the JUMP skips the catch handler).
        if (eval_try_tracking && self.check(TokenType.FINALLY)) {
            self.emit_abc(Opcode.LDREG, (uint)try_completion_reg, (uint)self.eval_acc_reg, 0);
        }
    }

    // Parse finally clause
    if (self.match(TokenType.FINALLY)) {
        has_finally = true;
        finally_tgt = self.code_count;

        // Patch the jump from the try block to land at FINALLY
        self.patch_jump(jump_over);

        // Emit FINALLY marker
        self.emit_simple(Opcode.FINALLY);

        // In eval mode, reset eval_acc_reg to undefined at the start of the
        // finally block.  Per ES2015 §13.15.1, `If F.[[Type]] is normal, set
        // F to C. Return Completion(UpdateEmpty(F, undefined)).`, but for
        // abrupt completions (break/continue/return/throw) inside the finally
        // block with no preceding expression statement, the abrupt
        // completion's empty value must surface as undefined (UpdateEmpty),
        // not leak the try block's value B.  Setting eval_acc_reg = undefined
        // here means a `break;` with no preceding expression leaves eval_acc
        // as undefined when ENDFINALLY jumps away to handle the abrupt
        // completion.  Matches the pattern in while/for/switch which reset
        // eval_acc_reg at the top of each iteration.
        if (eval_try_tracking) {
            self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
        }

        // Compile finally block
        self.block(false)!;

        // In eval mode, restore eval_acc_reg from the saved try/catch
        // completion value.  This runs only on the normal completion path
        // (return/break/continue/throw are handled by ENDFINALLY which
        // jumps away before reaching this restore).
        if (eval_try_tracking) {
            self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)try_completion_reg, 0);
        }

        // Emit ENDFINALLY
        self.emit_simple(Opcode.ENDFINALLY);
    } else {
        // Patch jump to skip catch handler
        self.patch_jump(jump_over);
    }

    // Free the completion-value temp register
    if (eval_try_tracking) {
        self.free_reg(try_completion_reg);
    }

    // Patch TRY instruction: A=flags, BC=catch_offset
    uint try_flags = (has_catch ? 1u : 0u) | (has_finally ? 2u : 0u);
    uint catch_offset = catch_target - try_addr;
    self.code[try_addr] = bytecode::make_a_bc(Opcode.TRY, try_flags, catch_offset);

    // Patch jump slot: BC=finally_offset (0 if no finally)
    uint finally_off = has_finally ? (finally_tgt - try_addr) : 0;
    self.code[jump_slot_addr] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);

    // Pop try info
    if (self.try_depth > 0) {
        self.try_depth--;
    }
}

// Parse switch statement with correct fall-through (ES5 §12.11).
//
// Each case body ends with a fall-through redirect JUMP patched after all
// case clauses are parsed, so that when a matched case body completes (without
// break) execution continues to the next case body rather than re-checking
// the next case's comparison preamble. The `default` clause is handled with
// a preamble JUMP when it is not the last clause, allowing subsequent cases
// to be checked before falling through to default on no match.
fn void? CompilerContext.switch_statement(&self) {
    self.expect(TokenType.SWITCH)!;
    self.expect(TokenType.LPAREN)!;

    ushort disc_reg = self.expression()!;
    // A bare identifier discriminant resolves to the binding's home register,
    // which the switch must not free at its end: that would pop next_reg
    // below the live local and hand its slot to the next temp allocation
    // (the case-literal LDINT of a following statement landed there and
    // turned every comparison into a self-compare).
    bool disc_is_local = self.last_was_local_var && self.last_local_var_reg == disc_reg;

    self.expect(TokenType.RPAREN)!;
    self.expect(TokenType.LBRACE)!;

    // Push a "loop" for break handling (break in switch exits the switch)
    // is_loop=false so continue skips this entry. This captures
    // cur_lex_depth BEFORE the CaseBlock's own lexical scope below, so a
    // `break` correctly POP_LEXes past the CaseBlock scope on its way out.
    self.push_loop(self.code_count, false);

    // ES2015 §14.12 / §13.12.9: CaseBlockEvaluation runs against a fresh
    // lexical environment (blockEnv) produced by BlockDeclarationInstantiation
    // over the CaseBlock, let/const/class/hoisted-function declarations made
    // directly in any case/default clause are scoped to the switch and must
    // not leak into the enclosing scope. This mirrors block()'s handling of
    // `{ ... }` blocks exactly, just with a wider pre-scan (block() only
    // needs let/const because class/function declarations there are already
    // handled by their own scoping, switch's CaseBlock is the one place
    // those additionally need confining).
    uint saved_switch_scope_depth = self.scope_depth;
    self.push_scope_marker();

    NameSpan[MAX_PRESCAN_NAMES] switch_lex_spans;
    uint num_switch_lex = self.pre_scan_switch_lexical_decls(&switch_lex_spans, MAX_PRESCAN_NAMES);

    // ES2024 §14.12.1 Static Semantics: Early Errors for
    // `SwitchStatement : switch ( Expression ) CaseBlock`. The whole CaseBlock
    // is one StatementList, so its clauses share a single lexical scope and get
    // the same two duplicate-name rules a BlockStatement does: no duplicate
    // LexicallyDeclaredNames, and no name in both LexicallyDeclaredNames and
    // VarDeclaredNames.
    self.check_duplicate_lexical_names(&switch_lex_spans[0], num_switch_lex)!;
    self.check_lexical_var_conflicts(&switch_lex_spans[0], num_switch_lex)!;

    bool switch_has_lex = num_switch_lex > 0;
    if (switch_has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
    }

    // TDZ-initialize every lexical declaration found by the pre-scan, exactly
    // like block()'s INITTZ pass, so accessing any of these names before their
    // declaration (or from outside the switch after it ends) throws a
    // ReferenceError instead of resolving to an outer binding.
    //
    // A top-level FunctionDeclaration in a clause is skipped, exactly as in
    // block(): §14.12.4 CaseBlockEvaluation runs BlockDeclarationInstantiation
    // over the whole CaseBlock before any clause is selected, and step
    // 3(a)(ii) instantiates such a declaration to its closure there rather
    // than leaving it uninitialized.
    for (uint i = 0; i < num_switch_lex; i++) {
        char[] name = self.name_span_text(switch_lex_spans[i]);
        if (!switch_lex_spans[i].is_fn) {
            uint name_idx = self.add_string_constant(name);
            self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
        }

        // Mark any outer scope_stack entry with the same name as captured so
        // the compiler emits GETVAR instead of LDREG for it, without this, a
        // register-cached outer value would bypass the binding we just
        // installed in the new lex_env.
        for (uint j = 0; j < saved_switch_scope_depth; j++) {
            if (str_eq(self.scope_stack[j].name, name)) {
                self.scope_stack[j].is_captured = true;
                self.has_captured_local = true;
                break;
            }
        }
    }

    // ES6 §13.12.9: CaseBlockEvaluation's initial value is V=undefined.
    // In eval mode, reset eval_acc_reg so a switch with no matching case
    // (or an empty CaseBlock) returns undefined per the spec, not the
    // previous expression statement's value.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Track all body entries (cases and default) in source order.
    //
    // These are fixed stack arrays and every write below is unguarded, so a
    // switch with more clauses than this wrote past the end of the compiler's
    // own frame. The old bound was 64, which real code exceeds easily — a
    // tokenizer or an AST visitor dispatching on a node kind routinely has
    // hundreds of cases, and typescript 5.4.5 has several. It corrupted the
    // stack SILENTLY: a 100-case switch still produced correct output while
    // writing 36 entries past the end.
    //
    // 1024 covers any plausible hand-written or generated switch; past that
    // the guard below reports a SyntaxError rather than corrupting memory.
    const uint MAX_SWITCH_CLAUSES = 1024;
    uint[MAX_SWITCH_CLAUSES] body_addrs;
    uint[MAX_SWITCH_CLAUSES] ft_jump_addrs;
    uint body_count = 0;
    bool has_default = false;
    uint default_body_idx = 0;
    bool default_not_last = false;

    // While compiling case/default bodies, function/generator/async-function
    // declarations found by the pre-scan above must bind into the switch's
    // own lex_env (PUTLEX) rather than the enclosing var_env (DECLVAR), see
    // force_lexical_fn_decl's doc comment.
    bool saved_force_lexical_fn_decl = self.force_lexical_fn_decl;
    if (switch_has_lex) {
        self.force_lexical_fn_decl = true;
    }

    // §14.12.4 / §14.2.11 step 3(a)(ii): instantiate the CaseBlock's top-level
    // FunctionDeclarations before any clause runs, so a call in an earlier
    // clause reaches a function declared in a later one. Saved/restored around
    // the CaseBlock so a nested block skips only its OWN declarations.
    NameSpan* saved_block_fn_spans = self.block_fn_spans;
    uint saved_block_fn_count = self.block_fn_count;
    defer {
        self.block_fn_spans = saved_block_fn_spans;
        self.block_fn_count = saved_block_fn_count;
    }
    if (switch_has_lex) {
        self.block_fn_spans = &switch_lex_spans[0];
        self.block_fn_count = num_switch_lex;
        self.emit_block_scoped_fn_decls(&switch_lex_spans[0], num_switch_lex)!;
    } else {
        self.block_fn_spans = null;
        self.block_fn_count = 0;
    }

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        // Both clause kinds below write body_addrs[body_count] and
        // ft_jump_addrs[body_count]. One check here dominates both, and fails
        // before any of the clause is compiled.
        if (body_count >= MAX_SWITCH_CLAUSES) {
            return self.fail("too many clauses in a switch statement")~;
        }
        if (self.match(TokenType.CASE)) {
            // Compile case expression.
            //
            // free_reg is strictly LIFO — it only pops when the freed register
            // is the top of the stack (`reg + 1 == next_reg`). Freeing
            // case_reg while cmp_reg sits above it is therefore a NO-OP, so
            // every clause leaked one register. With enough clauses the case
            // comparison register climbed past 255 (observed: r3, r4, ... r260
            // for 258 clauses) and the switch silently stopped matching —
            // arms 0..255 worked and everything past that fell to `default`.
            //
            // Record the allocator level before the case expression and
            // restore it once the comparison is emitted, which reclaims both
            // registers regardless of their relative order.
            ushort case_regs_base = self.next_reg;
            ushort case_reg = self.expression()!;
            self.expect(TokenType.COLON)!;

            // Compare discriminant with case value
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)disc_reg, (uint)case_reg);

            // Jump to the case body if they match
            uint match_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_regs_to(case_regs_base);

            // Jump over the body if no match
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch the match jump to here (the body)
            self.patch_jump(match_jump);
            body_addrs[body_count] = self.code_count;

            // Compile case body statements
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect jump (patched later to next body)
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Patch skip jump to after the fall-through redirect
            self.patch_jump(skip_jump);

        } else if (self.match(TokenType.DEFAULT)) {
            // §13.12.1: a CaseBlock may contain at most one DefaultClause.
            if (has_default) {
                return self.fail("More than one default clause in switch statement")~;
            }
            self.expect(TokenType.COLON)!;

            has_default = true;
            default_body_idx = body_count;

            // Emit preamble JUMP over default body (placeholder).
            // If more clauses follow, this skips the default body for the
            // case-checking path. If default is last, it becomes a no-op.
            uint default_preamble = self.emit_jump(Opcode.JUMP);

            body_addrs[body_count] = self.code_count;

            // Compile default body
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect for default
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Check if anything follows this default clause
            TokenType next = self.peek_type();
            if (next == TokenType.CASE || next == TokenType.DEFAULT) {
                // More clauses follow: preamble skips over default body
                self.patch_jump(default_preamble);
                default_not_last = true;
            } else {
                // Default is last: patch preamble to fall through to body
                // (offset 0 = jump to next instruction = body start)
                int ft_offset = (int)(body_addrs[default_body_idx]) -
                                (int)(default_preamble) - 1;
                self.code[default_preamble] =
                    bytecode::make_sabc(Opcode.JUMP, ft_offset);
            }
        } else {
            // Unexpected token in switch
            return COMPILE_ERROR~;
        }
    }

    self.force_lexical_fn_decl = saved_force_lexical_fn_decl;

    self.expect(TokenType.RBRACE)!;
    self.lexer.note_block_close();

    // If default is not last, emit a redirect for the 'no match' path at the
    // end of all case checks. This is reached by the last case's skip_jump.
    uint redirect_addr = 0;
    if (has_default && default_not_last) {
        redirect_addr = self.code_count;
        uint jump = self.emit_jump(Opcode.JUMP);
        // break jumps will be patched past this redirect by pop_loop
    }

    // Pop the CaseBlock's lexical scope, removing any let/const/class/function
    // bindings declared directly in a case/default clause. This must sit at
    // the address every "falls off the end" control-flow path converges on,
    // the last body's fall-through jump AND the "no match, no default" path
    // both target end_addr, so end_addr must point AT this POP_LEX (not past
    // it) or those paths would skip it entirely and leak the binding.
    // `break` unwinds past this scope separately via push_loop's
    // saved_lex_depth (see push_loop above), then jumps to end_addr itself,
    // executing this POP_LEX again would be wrong, so pop_loop's break jumps
    // are patched to AFTER this POP_LEX instead (see below).
    uint pop_lex_addr = self.code_count;
    if (switch_has_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    self.pop_scope_to(saved_switch_scope_depth);

    uint after_pop_lex_addr = self.code_count;

    // Patch break jumps to just after the POP_LEX (break already unwound the
    // CaseBlock's lex scope itself before jumping, so it must not execute
    // this POP_LEX a second time).
    self.pop_loop();

    uint end_addr = switch_has_lex ? pop_lex_addr : after_pop_lex_addr;

    // Patch the 'no match' redirect to the default body
    if (redirect_addr > 0) {
        int offset = (int)(body_addrs[default_body_idx]) -
                     (int)(redirect_addr) - 1;
        self.code[redirect_addr] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    // Patch all fall-through redirect jumps in source order
    for (uint i = 0; i < body_count; i++) {
        uint target;
        if (i + 1 < body_count) {
            // Fall through to next body in source order
            target = body_addrs[i + 1];
        } else {
            // Last body: fall through to end of switch
            target = end_addr;
        }
        int offset = (int)(target) - (int)(ft_jump_addrs[i]) - 1;
        self.code[ft_jump_addrs[i]] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    if (!disc_is_local) {
        self.free_reg(disc_reg);
    }
}

// Parse a labeled statement: `identifier : statement`.
// Supports labeled break and continue (ES5 §12.12).
fn void? CompilerContext.labeled_statement(&self, char[] name) {
    uint saved_label_count = self.label_count;

    // Check for duplicate labels
    for (uint i = 0; i < self.label_count; i++) {
        if (str_eq(self.labels[i].name, name)) {
            return COMPILE_ERROR~;
        }
    }

    // Register the label
    uint label_idx = self.label_count;
    if (label_idx >= MAX_LABELS) return COMPILE_ERROR~;
    self.labels[label_idx].name = name;
    self.label_count++;

    // Look ahead to determine if the inner statement is a loop, skipping any
    // nested labels (`target1: target2: while (...)` — both labels name the
    // same loop, so target1 must be marked is_loop too). Probing with a
    // lexer copy keeps the nested labels in place for the statement parser.
    TokenType next = self.peek_type();
    if (next == TokenType.IDENTIFIER) {
        Lexer scan = *self.lexer;
        scan.has_pushed_back = false;
        Token? nt_opt = scan.next_token();
        if (try nt = nt_opt) {
            if (nt.type == TokenType.IDENTIFIER) {
                Token? colon_opt = scan.next_token();
                if (try colon = colon_opt) {
                    if (colon.type == TokenType.COLON) {
                        Token? n2_opt = scan.next_token();
                        if (try n2 = n2_opt) {
                            next = n2.type;
                        }
                    }
                }
            }
        }
    }

    if (next == TokenType.FOR || next == TokenType.WHILE || next == TokenType.DO) {
        // The label refers to a loop. The loop will be pushed at index
        // self.loop_depth (the current depth before the loop's push_loop).
        self.labels[label_idx].loop_index = self.loop_depth;
        self.labels[label_idx].is_loop = true;
        self.statement_body()!;
    } else {
        // Non-loop label, push a virtual loop entry so break can target it.
        self.push_loop(self.code_count, false);
        self.labels[label_idx].loop_index = self.loop_depth - 1;
        self.labels[label_idx].is_loop = false;
        self.statement_body()!;
        self.pop_loop(); // patches all breaks targeting this label
    }

    // Labels are visible only while their labelled item is being compiled.
    // Keeping completed labels in the function-wide table incorrectly rejects
    // later statements that reuse the same label name (ES5 for-loop tests do
    // this several times in one script).
    self.label_count = saved_label_count;
}

// Parse break statement.
// If an identifier follows `break`, it's a labeled break (ES5 §12.12).
// A line terminator between `break` and the identifier means unlabeled break.
fn void? CompilerContext.break_statement(&self) {
    self.expect(TokenType.BREAK)!;

    if (self.peek_is_binding_identifier() && !self.lexer.seen_line_term) {
        // Labeled break, find the label and add jump to its loop's break chain.
        // A LabelIdentifier is an Identifier, so an escaped spelling is a
        // plain name — the same rule that let the label be DEFINED.
        Token label_tok = self.advance(true)!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                uint loop_idx = self.labels[i].loop_index;
                // Unwind the lex_env stack back to the labeled loop's depth.
                // Same pattern as the unlabeled break below, the labeled
                // branch was previously missing this, so a `break label`
                // inside a labeled block with a `let` (which pushed a
                // PUSH_LEX via block()) left the inner binding visible after
                // the jump.  Patching jumps via pop_loop() targets the
                // address AFTER the block's own POP_LEX (since break doesn't
                // fall through), so we must pop here at the jump site to
                // keep the runtime lex_env stack balanced.
                int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
                while (self.cur_lex_depth > target_lex) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }
                // IteratorClose for every for-of loop being exited, innermost
                // first, down to AND INCLUDING the labeled loop (a labeled break
                // exits loop_idx itself). For for-await loops this awaits the
                // AsyncIteratorClose (§7.4.11).
                for (int li = (int)self.loop_depth - 1; li >= (int)loop_idx; li--) {
                    if (self.loop_stack[li].iter_close_reg >= 0) {
                        self.emit_unwind_iter_close((uint)li);
                    }
                }
                uint jump_addr = self.emit_jump(self.loop_jump_op(loop_idx, Opcode.BREAK));
                self.loop_stack[loop_idx].break_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].break_patch_head, jump_addr);
                self.expect_semicolon_or_asi()!;
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled break, break out of the innermost loop or switch.
    // ES6 §13.13.1 BreakStatement : break ;, must be enclosed by an
    // IterationStatement or SwitchStatement. If there is none, this is a
    // SyntaxError (the BREAK opcode would otherwise dangle with no patch).
    if (self.loop_depth == 0) {
        return self.fail("'break' is only valid inside a loop or switch")~;
    }
    // Unwind the lex_env stack back to the loop's depth. Any nested blocks
    // that pushed PUSH_LEX must be popped before the break jumps, otherwise
    // the loop's outer-scope GETVARs will resolve to the wrong env.
    int loop_idx = (int)self.loop_depth - 1;
    int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
    while (self.cur_lex_depth > target_lex) {
        self.emit_simple(Opcode.POP_LEX);
        self.cur_lex_depth--;
    }
    // IteratorClose: if breaking from a for-of loop, close the iterator.
    if (self.loop_stack[loop_idx].iter_close_reg >= 0) {
        self.emit_unwind_iter_close((uint)loop_idx);
    }
    uint jump_addr = self.emit_jump(self.loop_jump_op((uint)loop_idx, Opcode.BREAK));
    self.add_break_patch(jump_addr);

    self.expect_semicolon_or_asi()!;
}

// Parse continue statement.
// If an identifier follows `continue`, it's a labeled continue (ES5 §12.12).
// A line terminator between `continue` and the identifier means unlabeled continue.
fn void? CompilerContext.continue_statement(&self) {
    self.expect(TokenType.CONTINUE)!;

    if (self.peek_is_binding_identifier() && !self.lexer.seen_line_term) {
        // Labeled continue, find the label and jump to its loop's continue
        // target. Same Identifier grammar as the labeled break above.
        Token label_tok = self.advance(true)!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                if (!self.labels[i].is_loop) {
                    // continue on a non-loop label is a syntax error
                    return self.fail("'continue' may only target a loop label")~;
                }
                uint loop_idx = self.labels[i].loop_index;
                // Unwind lex_env stack back to the labeled loop's depth.
                int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
                while (self.cur_lex_depth > target_lex) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }
                // IteratorClose: emit for any for-of loops being exited
                // (all loops from innermost down to but NOT including loop_idx).
                for (int li = (int)self.loop_depth - 1; li > (int)loop_idx; li--) {
                    if (self.loop_stack[li].iter_close_reg >= 0) {
                        self.emit_unwind_iter_close((uint)li);
                    }
                }
                // Use deferred patching so the continue target can be updated
                // after the body is compiled (needed for rotated for-loops where
                // continue_target is set to incr_label after body compilation).
                uint jump_addr = self.emit_jump(self.loop_jump_op(loop_idx, Opcode.CONTINUE));
                self.loop_stack[loop_idx].continue_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
                self.expect_semicolon_or_asi()!;
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled continue, jump to continue target of the innermost *real* loop
    // (skip switch pseudo-loops that only handle break)
    int loop_idx = (int)self.loop_depth - 1;
    while (loop_idx >= 0 && !self.loop_stack[loop_idx].is_loop) {
        loop_idx--;
    }
    if (loop_idx >= 0) {
        // Unwind lex_env stack back to the loop's depth.
        int target_lex = self.loop_stack[loop_idx].saved_lex_depth;
        while (self.cur_lex_depth > target_lex) {
            self.emit_simple(Opcode.POP_LEX);
            self.cur_lex_depth--;
        }
        // Emit placeholder jump and add to continue_patch_head for deferred patching
        uint jump_addr = self.emit_jump(self.loop_jump_op((uint)loop_idx, Opcode.CONTINUE));
        self.loop_stack[loop_idx].continue_patch_head =
            self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
    } else {
        return COMPILE_ERROR~;
    }

    self.expect_semicolon_or_asi()!;
}

// Parse expression statement.
fn void? CompilerContext.expression_statement(&self) {
    // The statement's value is discarded, except in eval, where the last
    // expression statement supplies the implicit completion value. Signal the
    // void context so a plain assignment can skip its result-preservation moves.
    if (!self.eval_mode) {
        self.void_ctx = true;
        self.postfix_void = true;
    }
    ushort reg = self.expression()!;
    if (self.eval_mode) {
        // Preserve the expression result for eval's implicit return value
        self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)reg, 0);
    }
    // Don't free a register that is the slot of a live local variable AND is
    // the top of the register stack (so free_reg would actually decrement).
    // Freeing the var slot would decrement next_reg past the slot, allowing
    // subsequent alloc_reg calls to clobber the variable's value.
    // (`var x = ...; x = ...;` returns the LHS register as the expression
    // result; freeing it after the standalone statement clobbers `x`.)
    if (reg + 1 != self.next_reg || !self.is_local_var_reg(reg)) {
        self.free_reg(reg);
    }
    self.expect_semicolon_or_asi()!;
}

// Parse a function declaration (hoisted).
// This is called during normal statement parsing for function declarations
// that were NOT hoisted during the pre-scan phase.
fn void? CompilerContext.function_declaration(&self, bool is_async_decl = false, uint async_kw_start = 0xFFFFFFFF) {
    self.expect(TokenType.FUNCTION)!;
    // Capture the byte offset of the `function` keyword before any subsequent
    // consume (identifier / star) clobbers lexer.token_start. Used downstream
    // by Function.prototype.toString for ES2019 §19.2.3.5 source retention.
    // For async declarations, async_kw_start provides the byte offset of the
    // `async` keyword, and we use that instead of fn_kw_start.
    uint fn_kw_start = is_async_decl && async_kw_start != 0xFFFFFFFF ? async_kw_start : self.lexer.token_start;

    // Check if this function declaration was already hoisted during pre-scan
    // If so, skip it entirely to avoid duplicate compilation.
    // For global scope, check against hoisted_fn_names.
    //
    // Not for a block-scoped declaration (force_lexical_fn_decl): a name in
    // hoisted_fn_names is a Script-level VarDeclaredName, a DIFFERENT binding
    // from the one this declaration creates in the block's lex_env, so matching
    // on it skipped a block-scoped `function outer(){}` that merely shared a
    // name with a top-level one, leaving the block's binding never emitted and
    // every read inside the block resolving to the global.
    if (self.is_global && !self.force_lexical_fn_decl) {
        // Extract function name from current lexer position. A `function*`
        // generator's name is TWO tokens ahead (`*` then the identifier), and
        // the lexer's single-slot pushback can't hold both, use the
        // CompilerContext's 4-deep token pushback stack instead (already used
        // elsewhere for the same "peek N, put all back" pattern, e.g.
        // peek2_is_lparen), pushing back in reverse order so `advance()`
        // replays them in their original order for the fallthrough re-parse.
        //
        // (A prior version pushed the `*` back onto the lexer's single slot
        // and immediately called next_token() again, which just re-read the
        // same `*`, the "already hoisted" name lookup below always saw
        // name_opt.type == STAR, never IDENTIFIER, so every module-level
        // generator declaration fell through to re-compile and re-run
        // CLOSURE+DECLVAR at its own textual position, re-instantiating a
        // fresh closure that link-time hoisting had already installed once.)
        // Pure lookahead: both tokens are pushed back below and re-read by
        // expect_binding_identifier, which owns the escaped-keyword decision
        // for this position, so this peek must not pre-empt it.
        Token star_opt = self.advance(true)!;
        Token name_opt = star_opt.type == TokenType.STAR ? self.advance(true)! : star_opt;
        if (name_opt.type == TokenType.IDENTIFIER) {
            char[] fn_name = name_opt.str_value;
            if (fn_name.len > 0) {
                // Check if already hoisted
                bool already = false;
                for (ushort hi = 0; hi < self.hoisted_fn_count; hi++) {
                    if (str_eq(self.hoisted_fn_names[hi], fn_name)) {
                        already = true;
                        break;
                    }
                }
                if (already) {
                    // TypeScript overload chains: the name was hoisted from
                    // the implementation that follows, and this occurrence may
                    // be a signature-only overload. Consume it when it is; a
                    // signature has no body, and scanning for a `{` would
                    // land inside the next declaration's object/mapped return
                    // type.
                    if (self.lexer.ts_mode && self.ts_try_skip_overload_signature()) {
                        self.lexer.note_block_close();
                        return;
                    }
                    // Skip the rest of the function body
                    self.skip_function_body();
                    // The body's closing `}` is a statement/declaration
                    // boundary, a following `/` starts a regexp literal.
                    self.lexer.note_block_close();
                    return;
                }
            }
        }
        // Not already hoisted (or not an identifier at all, e.g. a stray
        // token the later expect_binding_identifier() will properly reject):
        // put both tokens back (LIFO, name first, so `*` pops first) for
        // normal processing to re-consume in original order.
        if (star_opt.type == TokenType.STAR) {
            self.pushback(name_opt);
            self.pushback(star_opt);
        } else {
            self.pushback(name_opt);
        }
    }

    // Function declarations are hoisted to function scope, need env.
    self.has_local_bindings = true;

    // Save and reset generator state: nested function declarations
    // inside a generator do not inherit the generator flag.
    bool saved_is_generator = self.is_generator;
    bool saved_is_user_generator = self.is_user_generator;
    self.is_generator = false;
    self.is_user_generator = false;

    // Save the enclosing function's async flag, it must survive this
    // declaration (finish() reads it when the enclosing body completes).
    // The declaration's own async-ness comes from the is_async_decl
    // parameter, never from the enclosing flag. The reset is deliberately
    // deferred until after the name is parsed: unlike a FunctionExpression,
    // a FunctionDeclaration's BindingIdentifier is [?Yield, ?Await] and so
    // inherits the enclosing grammar params, which is what makes the inner
    // name in `async function f(){ function await(){} }` a SyntaxError even
    // though the inner function is itself ordinary.
    bool saved_is_async = self.is_async;

    // Regular function declarations are constructable per ES2015 §14.1.2, they
    // can be invoked with `new` if they aren't arrow functions or methods with
    // super. Save/restore the constructable flag around the inner compile so
    // nested functions inside it inherit it.
    bool saved_is_constructable = self.is_constructable;
    self.is_constructable = true;

    // Check for generator star: function* name() {}
    // Generator functions are never constructable (ES2015 §14.4), `new` on
    // one must throw TypeError, so is_constructable must flip to false here.
    if (self.match(TokenType.STAR)) {
        // `function*` and `async function*` are both syntactic generators.
        self.is_generator = true;
        self.is_user_generator = true;
        self.is_constructable = false;
    }

    // Async functions are not constructors (ES2017 §14.7.5, no [[Construct]]).
    if (is_async_decl) {
        self.is_constructable = false;
    }

    Token name_tok = self.expect_binding_identifier()!;
    // The name is parsed; from here on self.is_async describes the function
    // being compiled, not the enclosing one.
    self.is_async = false;
    // TypeScript overload signature (`function foo(x: T);`): a declaration
    // without a body produces no runtime binding, so skip it and restore the
    // enclosing context flags. The implementation emits its own CLOSURE at
    // its own position. Global signatures never reach here: their name was
    // recorded by hoist_global_fn_decls from the implementation, so the
    // already-hoisted path above consumed them.
    if (self.lexer.ts_mode && self.ts_try_skip_overload_signature()) {
        self.is_async = saved_is_async;
        self.is_generator = saved_is_generator;
        self.is_user_generator = saved_is_user_generator;
        self.is_constructable = saved_is_constructable;
        return;
    }
    // Intern now: an escaped function name borrows the lexer's shared
    // ident_buf scratch, which compile_inner_function below will overwrite
    // while scanning the parameter list and body. declare_var stores this
    // slice into scope_stack, which outlives the current token.
    HString* fn_name_hstr = ((Heap*)self.heap).str_intern(name_tok.str_value);
    char[] fn_name2 = fn_name_hstr.get_data();

    // A declaration the body-scope hoist pass recorded is skipped here:
    // block() already instantiated its binding just after PUSH_LEX. Emitting
    // again at the textual position would create a SECOND function object and
    // rebind the name to it, so a property stored on the binding beforehand
    // (`exports.c = c; function c(){} c.stat = 1`) would end up on an object
    // nothing else references -- and for a repeated name it would additionally
    // rebind a body §10.2.11 says is superseded.
    for (ushort di = 0; di < self.hoisted_defer_count; di++) {
        if (str_eq(self.hoisted_defer_names[di], fn_name2)) {
            self.skip_function_body();
            self.lexer.note_block_close();
            self.is_async = saved_is_async;
            self.is_generator = saved_is_generator;
            self.is_user_generator = saved_is_user_generator;
            self.is_constructable = saved_is_constructable;
            return;
        }
    }

    // Same rule one scope down: a top-level FunctionDeclaration of the
    // enclosing BlockStatement / CaseBlock was already instantiated at that
    // block's entry by emit_block_scoped_fn_decls (§14.2.11 step 3(a)(ii)), so
    // the textual pass only has to step over it. block_fn_spans is cleared
    // while that eager pass itself runs, so this never skips the very
    // declaration being compiled.
    for (uint bi = 0; bi < self.block_fn_count; bi++) {
        if (!self.block_fn_spans[bi].is_fn) continue;
        if (str_eq(self.name_span_text(self.block_fn_spans[bi]), fn_name2)) {
            self.skip_function_body();
            self.lexer.note_block_close();
            self.is_async = saved_is_async;
            self.is_generator = saved_is_generator;
            self.is_user_generator = saved_is_user_generator;
            self.is_constructable = saved_is_constructable;
            return;
        }
    }

    // A redeclaration in the same scope is the same binding, so reuse its
    // register instead of allocating a second one. Declaring afresh leaves
    // code emitted between the two declarations (`function f(){} f.a = 1;
    // function f(){}`) pointing at the first register while every later read
    // resolves to the second, so the property write silently disappears.
    // Same reuse rule var_declaration applies via find_local_reg, but seeing
    // through the body marker the hoist pass declared beneath, so a
    // block-nested declaration still keeps its own binding.
    ushort func_reg;
    ushort? existing_fn_reg = self.find_same_scope_reg(fn_name2);
    if (try efr = existing_fn_reg) {
        func_reg = efr;
    } else {
        func_reg = self.declare_var(fn_name2, VAR);
    }

    // Compile the function into a nested CompiledFunction with the
    // declaration's own async flag, then restore the enclosing one.
    self.is_async = is_async_decl;
    CompiledFunction* inner = self.compile_inner_function(fn_name2, false, fn_kw_start)!;
    self.is_async = saved_is_async;

    // Restore generator flag
    self.is_generator = saved_is_generator;
    self.is_user_generator = saved_is_user_generator;
    // Restore constructable flag (arrow fns/methods strip it via their own save/restore)
    self.is_constructable = saved_is_constructable;

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    // Emit CLOSURE to create the function object
    self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);

    uint name_idx = self.add_string_constant(fn_name2);
    if (self.force_lexical_fn_decl) {
        // Inside a switch CaseBlock: scope this declaration to the switch's
        // own lex_env (installed by switch_statement's PUSH_LEX) instead of
        // the function-scoped var_env, so it disappears when the switch's
        // POP_LEX runs, matching BlockDeclarationInstantiation (§14.12).
        self.emit_a_bc(Opcode.PUTLEX, (uint)func_reg, name_idx);
    } else {
        // Declare the binding in the immediate var_env so inner functions can
        // find it via GETVAR. DECLGLOBALFUNC matches DECLVAR for a declarative
        // var_env and applies CreateGlobalFunctionBinding's descriptor rules
        // when the var_env is the global Environment Record.
        self.emit_a_bc(Opcode.DECLGLOBALFUNC, (uint)func_reg, name_idx);
    }

    // At global scope, free the register, the function object lives in the
    // environment via GETVAR/PUTVAR, not in a register-cached scope slot.
    if (self.is_global) {
        self.free_reg(func_reg);
    }
}

// ============================================================================
// ESM Import/Export declarations
// ============================================================================

// True when `tok` is the contextual keyword `of` that heads a for-of loop.
//
// `of` is not a reserved word, so it arrives as a plain IDENTIFIER and has to
// be matched on its text. An escaped spelling is never the keyword (ES2024
// §12.6.1), so `for (var x of [])` is a SyntaxError rather than a for-of
// loop -- the same rule expect_as / expect_from apply to `as` and `from`.
fn bool token_is_of(Token tok) {
    return tok.type == TokenType.IDENTIFIER && !tok.has_escape && str_eq(tok.str_value, "of");
}

// Get the CompModuleDef* from the opaque current_module pointer.
// Returns null if not in module mode.
fn CompModuleDef* CompilerContext.get_module_def(&self) {
    return (CompModuleDef*)self.current_module;
}

// Expect the contextual keyword `from` (not a reserved word, must be
// checked as an identifier with value "from").
//
// An escaped spelling is never the keyword (ES2024 §12.6.1: a
// ReservedWord/contextual keyword must be written with no UnicodeEscape-
// Sequence), so `\u0066rom` is a plain identifier here and a SyntaxError.
fn void? CompilerContext.expect_from(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (tok.has_escape || !str_eq(tok.str_value, "from")) {
        return COMPILE_ERROR~;
    }
}

// Match the contextual keyword `from`, consumes and returns true if the
// current token is the identifier "from".
fn bool CompilerContext.match_from(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    // Peek at the actual token to check the string value
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (!tok.has_escape && str_eq(tok.str_value, "from")) {
        return true;
    }
    // Not 'from' (or an escaped spelling, which §12.6.1 makes a plain
    // identifier rather than the keyword), push back
    self.lexer.pushback(tok);
    return false;
}

// Expect the contextual keyword `as`. An escaped spelling is never the
// keyword (§12.6.1), so `\u0061s` is a SyntaxError here.
fn void? CompilerContext.expect_as(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (tok.has_escape || !str_eq(tok.str_value, "as")) {
        return COMPILE_ERROR~;
    }
}

// Match the contextual keyword `as`.
fn bool CompilerContext.match_as(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (!tok.has_escape && str_eq(tok.str_value, "as")) {
        return true;
    }
    self.lexer.pushback(tok);
    return false;
}

// Parse an optional WithClause (ES2025 import attributes) after a module
// specifier, e.g. `with { type: "json" }`. Returns true when a `type: "json"`
// attribute was present so the caller can register a JSON module request.
//
//   WithClause : with { }
//              | with { WithEntries ,opt }
//   WithEntries : AttributeKey : StringLiteral
//               | AttributeKey : StringLiteral , WithEntries
//   AttributeKey : IdentifierName | StringLiteral
//
// Syntax errors (early / parse phase): a non-string attribute value, a
// missing `:`, and duplicate attribute keys (compared after escape decoding).
// Unknown keys and unknown `type` values are NOT parse errors, they are left
// for the host load step, matching the spec and the test262 corpus (the
// resolution-phase tests rely on the syntax being accepted).
fn bool? CompilerContext.parse_with_clause(&self) {
    // No WithClause present.
    if (self.peek_type() != TokenType.WITH) return false;
    self.advance()!;  // consume 'with'
    self.expect(TokenType.LBRACE)!;

    // Collect decoded attribute keys to detect duplicates. MAX 32 entries is
    // plenty (the corpus's largest is 4); overflow simply stops collecting.
    char[][32] seen_keys;
    uint seen_count = 0;
    bool wants_json = false;

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        // AttributeKey: an IdentifierName (incl. reserved words like `if`,
        // `type`) or a StringLiteral.
        char[] key_str;
        if (self.check(TokenType.STRING)) {
            Token key_tok = self.advance()!;
            key_str = key_tok.str_value;
        } else {
            key_str = self.read_property_name()!;
        }
        if (key_str.len == 0) return self.fail("invalid import attribute key")~;

        // Duplicate-key check (compared on decoded values).
        for (uint i = 0; i < seen_count; i++) {
            if (str_eq(seen_keys[i], key_str)) {
                return self.fail("duplicate import attribute key")~;
            }
        }
        if (seen_count < 32) { seen_keys[seen_count] = key_str; seen_count++; }

        self.expect(TokenType.COLON)!;

        // AttributeValue MUST be a StringLiteral.
        if (!self.check(TokenType.STRING)) {
            return self.fail("import attribute value must be a string literal")~;
        }
        Token val_tok = self.advance()!;

        if (str_eq(key_str, "type") && str_eq(val_tok.str_value, "json")) {
            wants_json = true;
        }

        if (!self.match(TokenType.COMMA)) break;
    }
    self.expect(TokenType.RBRACE)!;
    return wants_json;
}

// Parse a `ModuleExportName : IdentifierName | StringLiteral` (§16.2.3).
//
// `was_string`, when non-null, receives whether the StringLiteral form was
// taken. Callers need it for the two places the grammar treats the forms
// differently: a string ModuleExportName must be well-formed Unicode, and a
// `NamedExports` with no `from` clause may not use one at all (both below).
fn char[]? CompilerContext.parse_module_export_name(&self, bool* was_string = null) {
    Token tok = self.lexer.next_token()!;
    if (was_string != null) *was_string = (tok.type == TokenType.STRING);
    if (tok.type == TokenType.STRING) {
        // §16.2.3.1: "It is a Syntax Error if IsStringWellFormedUnicode of the
        // StringValue of StringLiteral is false." A lone surrogate could not be
        // spelled by any importer, so the name would be unusable.
        if (!hstring::is_well_formed_unicode(tok.str_value)) {
            return self.fail("a module export name must be well-formed Unicode")~;
        }
        return self.intern_slot_name(tok.str_value);
    }
    if (tok.type == TokenType.IDENTIFIER) {
        return self.intern_slot_name(tok.str_value);
    }
    char[] kw = lexer::keyword_to_string(tok.type);
    if (kw.len > 0) {
        return self.intern_slot_name(kw);
    }
    return COMPILE_ERROR~;
}

// Parse an ESM import declaration (ES6 §15.2.2).
//
// Forms:
//   import 'module'
//   import defaultName from 'module'
//   import { a, b as c } from 'module'
//   import * as ns from 'module'
//   import defaultName, { a } from 'module'
//   import defaultName, * as ns from 'module'
fn void? CompilerContext.import_declaration(&self) {
    if (!self.is_module) {
        io::eprintfn("import declarations are only allowed in modules");
        return COMPILE_ERROR~;
    }

    self.expect(TokenType.IMPORT)!;

    if (self.current_module == null) return COMPILE_ERROR~;
    CompModuleDef* mod = self.get_module_def();

    TokenType tt = self.peek_type();

    // Side-effect import: import 'module'
    if (tt == TokenType.STRING) {
        Token spec_tok = self.advance()!;
        bool wants_json = self.parse_with_clause()!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // import defaultName ...
    bool has_default = false;
    char[] default_local = {};
    if (tt == TokenType.IDENTIFIER) {
        Token name_tok = self.advance()!;
        // Intern now: default_local is stored in the module's import table
        // and read back at link time, long after the rest of the module
        // (and any later escaped identifiers) has been lexed. An escaped
        // identifier's str_value borrows the lexer's transient ident_buf.
        default_local = self.intern_slot_name(name_tok.str_value);
        has_default = true;

        if (self.peek_type() == TokenType.COMMA) {
            self.advance()!; // consume ','
        } else {
            // Must be: import defaultName from 'module'
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            bool wants_json = self.parse_with_clause()!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
            mod_register_import(mod, default_local, "default", req_idx, false, true);
            self.match(TokenType.SEMICOLON);
            return;
        }
    }

    tt = self.peek_type();

    // import * as ns from 'module'
    if (tt == TokenType.STAR) {
        self.advance()!; // consume '*'
        self.expect_as()!;
        // NameSpaceImport's `as` is followed by an ImportedBinding, i.e. a
        // BindingIdentifier, so `import * as eval from ...` is a SyntaxError.
        Token ns_tok = self.expect_binding_identifier()!;
        // Intern now: stored in the module's import table and read back at
        // link time, long after the rest of the module has been lexed.
        char[] ns_local = self.intern_slot_name(ns_tok.str_value);
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        bool wants_json = self.parse_with_clause()!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
        mod_register_import(mod, ns_local, "*", req_idx, true, false);
        if (has_default) {
            mod_register_import(mod, default_local, "default", req_idx, false, true);
        }
        self.match(TokenType.SEMICOLON);
        return;
    }

    // import { a, b as c } from 'module'
    if (tt == TokenType.LBRACE) {
        self.advance()!; // consume '{'

        // We need to collect specifiers first, then get the module specifier,
        // then emit bindings. Parse the specifier string first by peeking ahead.
        // Actually, we need the req_idx first. Let's parse specifiers into temp arrays.
        char[][32] local_names;
        char[][32] import_names;
        uint binding_count = 0;

        while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
            if (binding_count >= 32) return COMPILE_ERROR~;

            // TS inline type specifier: `import { type X, value }` erases
            // X's binding entirely. Only a `type` followed by another name
            // is the qualifier; a lone `type` (`,` or `}` next) is a binding
            // literally named "type" and imports normally.
            bool erased_ts_type = false;
            if (self.lexer.ts_mode && self.check_ts_ident("type")) {
                Token type_kw = self.advance()!;
                TokenType after = self.peek_type();
                if (after == TokenType.IDENTIFIER || after == TokenType.STRING) {
                    erased_ts_type = true;
                } else {
                    self.pushback(type_kw);
                }
            }
            if (erased_ts_type) {
                char[] _erased = self.parse_module_export_name()!;
                if (self.match_as()) {
                    Token _erased_alias = self.expect_binding_identifier()!;
                }
                if (!self.match(TokenType.COMMA)) break;
                continue;
            }

            // The import name (before 'as') is a ModuleExportName (IdentifierName or StringLiteral).
            char[] import_name_str = self.parse_module_export_name()!;
            if (self.match_as()) {
                // `ModuleExportName as ImportedBinding`: the alias is a
                // BindingIdentifier, so `import { x as eval }` is a
                // SyntaxError even though `eval` is a fine export name.
                Token alias_tok = self.expect_binding_identifier()!;
                local_names[binding_count] = self.intern_slot_name(alias_tok.str_value);
                import_names[binding_count] = import_name_str;
            } else {
                // Without `as` the ImportSpecifier is a bare ImportedBinding,
                // so the one name is both the export name and a binding and
                // has to satisfy the BindingIdentifier restrictions too.
                if (is_restricted_name(import_name_str)) {
                    return self.fail("reserved word cannot be used as a binding identifier")~;
                }
                local_names[binding_count] = import_name_str;
                import_names[binding_count] = import_name_str;
            }
            binding_count++;

            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        bool wants_json = self.parse_with_clause()!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);

        // Register import metadata (bindings are created at link time by execute_module)
        for (uint i = 0; i < binding_count; i++) {
            mod_register_import(mod, local_names[i], import_names[i], req_idx, false, false);
        }

        if (has_default) {
            mod_register_import(mod, default_local, "default", req_idx, false, true);
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    return COMPILE_ERROR~;
}

// Parse an ESM export declaration (ES6 §15.2.3).
//
// Forms:
//   export function foo() {}
//   export class Foo {}
//   export const/let/var x = ...
//   export { a, b as c }
//   export { a } from './other'
//   export * from './other'
//   export * as ns from './other'
//   export default function() {}
//   export default <expr>
//   export default class {}
fn void? CompilerContext.export_declaration(&self) {
    if (!self.is_module) {
        io::eprintfn("export declarations are only allowed in modules");
        return COMPILE_ERROR~;
    }

    self.expect(TokenType.EXPORT)!;

    if (self.current_module == null) return COMPILE_ERROR~;
    CompModuleDef* mod = self.get_module_def();

    // `export async function foo() {}`, the `async` prefix is detected here
    // (before the FUNCTION dispatch below) so the same hoistable-declaration
    // path handles both sync and async forms.
    bool is_async_named_fn = self.match_async_function();
    TokenType tt = self.peek_type();

    // export default ...
    if (tt == TokenType.DEFAULT) {
        self.advance()!; // consume 'default'
        // TypeScript `export default interface Foo {...}` / `export default
        // type X = ...`: the whole declaration is type-only (erasable), no
        // runtime export is produced.
        if (self.lexer.ts_mode && self.peek_type() == TokenType.INTERFACE) {
            self.ts_interface_declaration()!;
            self.match(TokenType.SEMICOLON);
            return;
        }
        if (self.lexer.ts_mode && self.check_ts_ident("type")
            && self.ts_try_type_alias()) {
            return;
        }
        // `export default async function ...`, the `async` prefix is
        // detected before the FUNCTION dispatch below so the same
        // hoistable-declaration path handles both sync and async forms.
        bool is_async_default_fn = self.match_async_function();
        TokenType next = self.peek_type();

        // export default function() {} or export default function name() {}
        if (next == TokenType.FUNCTION) {
            self.advance()!; // consume 'function'
            // Byte offset of the `function` keyword before subsequent consumes
            // clobber lexer.token_start. Used by Function.prototype.toString.
            uint export_fn_src_start = self.lexer.token_start;
            bool is_gen = self.match(TokenType.STAR);
            if (is_gen) { self.is_generator = true; self.is_user_generator = true; }

            // Check for named function expression
            char[] fn_name;
            bool is_named = false;
            if (self.peek_type() == TokenType.IDENTIFIER) {
                Token name_tok = self.advance()!;
                // Intern now: an escaped function name borrows the lexer's
                // shared ident_buf scratch, which compile_inner_function
                // below will overwrite while scanning the parameter list and
                // body. declare_var stores this slice into scope_stack,
                // which outlives this token.
                fn_name = ((Heap*)self.heap).str_intern(name_tok.str_value).get_data();
                is_named = true;
            } else {
                // Anonymous `export default function(){}`: the internal
                // module-scope binding is the synthetic `*default*` slot, but
                // the function object's own `.name` is "default"
                // (SetFunctionName, §14.1.20 InstantiateFunctionObject step 4)
                //, a runtime-visible value, not the compiler-private symbol.
                fn_name = "default";
            }

            bool saved_is_async = self.is_async;
            self.is_async = false;
            // Regular functions are constructable (ES2015 §14.1.2); generators
            // and async functions never are (§14.4/§14.7.5), mirrors
            // function_declaration's handling.
            bool saved_is_constructable = self.is_constructable;
            // TypeScript overload signature as a default export:
            // `export default function f();` declares no implementation, so
            // it produces no runtime binding or export; a later
            // `export default function f(...) { }` (the implementation)
            // binds the export.
            if (self.lexer.ts_mode && self.ts_try_skip_overload_signature()) {
                self.is_async = saved_is_async;
                self.is_constructable = saved_is_constructable;
                self.is_generator = false;
                self.is_user_generator = false;
                return;
            }
            self.is_constructable = !self.is_generator && !is_async_default_fn;
            // The declaration's own async-ness comes from is_async_default_fn,
            // never the enclosing flag (mirrors function_declaration).
            self.is_async = is_async_default_fn;
            // Use the byte offset captured just past `self.advance()!` above.
            CompiledFunction* inner = self.compile_inner_function(fn_name, false, export_fn_src_start)!;
            self.is_constructable = saved_is_constructable;
            self.is_async = saved_is_async;
            self.is_generator = false;
            self.is_user_generator = false;

            uint inner_idx = self.add_inner_func(inner);

            // `export default function name` binds its own declared name in the
            // module scope (ECMA-262 §16.2.3.7 / ExportDeclaration), so the
            // function body can reference/reassign `name` and the "default"
            // export is a live binding of that same name. An anonymous
            // `export default function` binds the synthetic `*default*` slot.
            // Either way it is a hoisted function declaration bound at link
            // time (16.2.1.5.5 step 17); record it for the linker and suppress
            // body CLOSURE+DECLVAR so a cyclic early import sees the function.
            // fn_name is "default" for the anonymous case (used as the
            // function object's .name); the module-scope binding still uses
            // the internal "*default*" symbol so it can't collide with a
            // user-declared `default` identifier.
            char[] local_name = is_named ? fn_name : "*default*";
            // A module's top-level function declarations are lexical
            // (§16.2.1.1), and `export default function F(){}` binds `F` in
            // module scope just like a plain declaration, so it must not
            // collide with an existing lexical name.
            // check_module_duplicate_lexical_names cannot see this one: the
            // name is not in statement position, so hoist_global_fn_decls's
            // pre-scan never records it.
            if (is_named) self.check_module_lexical_collision(local_name)!;
            ushort func_reg = self.declare_var(local_name, VAR);
            mod_register_func_decl(mod, local_name, inner_idx);
            self.free_reg(func_reg);

            self.register_export(mod, local_name, "default", false, 0, false, true)!;
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default class {} or export default class Foo {}
        if (next == TokenType.CLASS) {
            // allow_anonymous: `export default class {}` has no BindingIdentifier
            // and binds to *default* (§16.2.3.7). A named `export default class
            // Foo {}` binds `Foo` in the module scope; the "default" export is a
            // live binding of that same name, so track the actual bound name
            // (class_declaration returns it), not always *default*.
            char[] dflt_class_name;
            self.class_declaration(&dflt_class_name, true)!;
            // A class declaration's outer binding is always lexical (`let`-style,
            // TDZ until the class evaluates), see class_declaration's class_reg
            // above, whether the class is named or the anonymous `*default*`
            // symbol. Registering this as non-lexical left link_module's
            // export pre-declaration loop seeding a plain `undefined` instead
            // of the TDZ sentinel, so a same-module self-import of the default
            // binding observed `undefined` instead of throwing ReferenceError.
            self.register_export(mod, dflt_class_name, "default", false, 0, true, true)!;
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default <expr>
        // If the expression is an anonymous function/class definition, its
        // inferred name is "default" (ECMA-262 §16.2.3.7: NamedEvaluation with
        // "default"). Seed the inferred-name slot so the anonymous definition
        // picks it up; a named/non-anonymous expression clears it itself.
        self.has_inferred_name = true;
        self.inferred_name_len = 7; // "default"
        char[] dflt_infer = "default";
        for (ushort i = 0; i < 7; i++) self.inferred_name_buf[i] = dflt_infer[i];
        ushort val_reg = self.assignment_expr()!;
        uint def_name_idx = self.add_string_constant("*default*");
        self.emit_a_bc(Opcode.DECLVAR, (uint)val_reg, def_name_idx);
        self.free_reg(val_reg);
        // `export default <expr>` binds the synthetic `*default*` as a mutable
        // lexical binding initialized at THIS statement's position (§16.2.3.7 /
        // ExportDeclaration:ClassExpression is lexical). Before the statement
        // runs it is in TDZ, so a same-module `import * as ns; ns.default`
        // executing above must observe the sentinel and throw ReferenceError,
        // register it lexical so link_module pre-declares the TDZ sentinel.
        self.register_export(mod, "*default*", "default", false, 0, true, true)!;
        // `export default AssignmentExpression ;` — the semicolon is part of
        // the production, so it is required (via ASI), unlike the
        // HoistableDeclaration / ClassDeclaration forms above, which end at
        // their own closing brace and take no semicolon.
        self.expect_semicolon_or_asi()!;
        return;
    }

    // export * from './other'
    if (tt == TokenType.STAR) {
        self.advance()!; // consume '*'

        // export * as ns from './other'
        if (self.match_as()) {
            char[] ns_name = self.parse_module_export_name()!;
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            bool wants_json = self.parse_with_clause()!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
            self.register_export(mod, "*", ns_name, true, req_idx)!;
            self.expect_semicolon_or_asi()!;
            return;
        }

        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        bool wants_json = self.parse_with_clause()!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
        mod_register_star_export(mod, req_idx);
        self.expect_semicolon_or_asi()!;
        return;
    }

    // export { a, b as c } or export { a } from './other'
    if (tt == TokenType.LBRACE) {
        self.advance()!; // consume '{'

        char[][32] local_names;
        char[][32] export_names;
        // Whether each specifier's LOCAL half used the StringLiteral form of
        // ModuleExportName. Only meaningful until the `from` test below, see
        // the early error there.
        bool[32] local_is_string;
        uint count = 0;

        while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
            if (count >= 32) return COMPILE_ERROR~;
            bool local_was_string = false;
            // TypeScript `export { type foo }` / `export { type foo as bar }`:
            // the `type` modifier marks a type-only specifier, fully erased
            // (it must not reach register_export or the linker would demand a
            // runtime binding the target never had). Only a modifier when
            // another export name follows on the same line; `export { type }`
            // exports a binding literally named "type".
            bool erased_ts_spec = false;
            if (self.lexer.ts_mode && self.check_ts_ident("type")) {
                Lexer saved_ts = *self.lexer;
                bool is_type_mod = false;
                Token? type_tok_opt = self.advance();
                if (catch _te = type_tok_opt) {
                    *self.lexer = saved_ts;
                } else {
                    Token type_tok = type_tok_opt;
                    // The name must follow on the same line as `type`
                    // (seen_line_term after advance describes the gap BEFORE
                    // `type`, e.g. the export-clause `{` newline).
                    Token? nxt_opt = self.lexer.peek();
                    if (try nxt = nxt_opt) {
                        is_type_mod = nxt.line == type_tok.line
                            && (nxt.type == TokenType.IDENTIFIER || nxt.type == TokenType.STRING);
                    }
                    *self.lexer = saved_ts;
                }
                if (is_type_mod) {
                    Token _tmod = self.advance()!;
                    erased_ts_spec = true;
                }
            }
            char[] local_str = self.parse_module_export_name(&local_was_string)!;
            char[] alias_str = local_str;
            if (self.match_as()) {
                alias_str = self.parse_module_export_name()!;
            }
            if (!erased_ts_spec) {
                local_is_string[count] = local_was_string;
                local_names[count] = local_str;
                export_names[count] = alias_str;
                count++;
            }
            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;

        // Check for 'from' clause (indirect export)
        if (self.match_from()) {
            Token spec_tok = self.expect(TokenType.STRING)!;
            bool wants_json = self.parse_with_clause()!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value, wants_json);
            for (uint i = 0; i < count; i++) {
                self.register_export(mod, local_names[i], export_names[i], true, req_idx)!;
            }
        } else {
            // `export { a, b as c };`, a, b are local bindings UNLESS one
            // already names an imported binding, in which case ECMA-262
            // §16.2.1.7.1 ParseModule step 10.1 reclassifies it as an
            // INDIRECT export sourced from that ImportEntry's own module/
            // import name (Table 59), never a local one. This is what makes
            // `import { foo } from './x'; export { foo };` re-export the
            // live binding from './x', including its own TDZ state,
            // rather than exporting a same-module local accessor that
            // never observes './x' at all.
            //
            // §16.2.3.1: "ExportDeclaration : export NamedExports ; — It is a
            // Syntax Error if ReferencedBindings of NamedExports contains any
            // ModuleExportName." Without a `from`, each specifier's local half
            // names a binding in THIS module, and a StringLiteral cannot be an
            // identifier, so `export { "foo" as "bar" }` is a SyntaxError even
            // when a `function foo(){}` exists. With a `from` the same half is
            // a name looked up in the other module, where a string is fine.
            for (uint i = 0; i < count; i++) {
                if (local_is_string[i]) {
                    return self.fail("a string module export name requires a 'from' clause")~;
                }
            }
            for (uint i = 0; i < count; i++) {
                CompImportEntry* ie = mod_find_import_by_local(mod, local_names[i]);
                if (ie != null) {
                    char[] indirect_local = ie.is_star ? "*" : ie.import_name;
                    self.register_export(mod, indirect_local, export_names[i], true, ie.req_module_idx)!;
                    continue;
                }
                // TypeScript: a specifier naming a type-only binding
                // (`interface G {}` then `export { G };`) has no runtime
                // value, so the export erases to nothing. tsc accepts this
                // under --erasableSyntaxOnly; registering the phantom export
                // would make the linker reject it.
                if (self.lexer.ts_mode && !self.ts_name_is_runtime_binding(local_names[i])) {
                    continue;
                }
                // Local export: look up the name's declared kind so a
                // re-export of an already-declared `let`/`const`/`class`
                // binding is TDZ-eligible too (e.g. `let a = 1; export { a };`).
                // A re-export of a top-level `function` declaration needs no
                // special handling here: the function is already recorded in
                // func_decls (by hoist_global_fn_decls) and bound at link
                // time, and this export simply aliases that local binding.
                bool lex = self.is_name_lexical(local_names[i]);
                self.register_export(mod, local_names[i], export_names[i], false, 0, lex)!;
            }
        }

        self.expect_semicolon_or_asi()!;
        return;
    }

    // export function foo() {}
    if (tt == TokenType.FUNCTION) {
        self.advance()!; // consume 'function'
        // Byte offset of the `function` keyword, captured before subsequent
        // consumes clobber lexer.token_start. Used by toString.
        uint named_export_src_start = self.lexer.token_start;
        bool is_gen = self.match(TokenType.STAR);
        if (is_gen) { self.is_generator = true; self.is_user_generator = true; }

        bool saved_is_async = self.is_async;
        self.is_async = false;

        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        // Intern now: an escaped function name borrows the lexer's shared
        // ident_buf scratch, which compile_inner_function below will
        // overwrite while scanning the parameter list and body. declare_var
        // stores this slice into scope_stack, which outlives this token.
        HString* fn_name_hstr = ((Heap*)self.heap).str_intern(name_tok.str_value);
        char[] fn_name2 = fn_name_hstr.get_data();

        // TypeScript overload signature (`export function f(x: T);`):
        // signature-only, produces no binding, func_decl, or export. The
        // implementation declaration later in the file registers all three.
        if (self.lexer.ts_mode && self.ts_try_skip_overload_signature()) {
            self.is_async = saved_is_async;
            self.is_generator = false;
            self.is_user_generator = false;
            return;
        }

        ushort func_reg = self.declare_var(fn_name2, VAR);

        // Regular functions are constructable (ES2015 §14.1.2); generators
        // and async functions never are (§14.4/§14.7.5), mirrors
        // function_declaration's handling.
        bool saved_is_constructable = self.is_constructable;
        self.is_constructable = !self.is_generator && !is_async_named_fn;
        // The declaration's own async-ness comes from is_async_named_fn,
        // never the enclosing flag (mirrors function_declaration).
        self.is_async = is_async_named_fn;
        CompiledFunction* inner = self.compile_inner_function(fn_name2, false, named_export_src_start)!;
        self.is_constructable = saved_is_constructable;
        self.is_async = saved_is_async;
        self.is_generator = false;
        self.is_user_generator = false;

        uint inner_idx = self.add_inner_func(inner);

        // A top-level `export function` declaration is instantiated at link
        // time (ECMA-262 16.2.1.5.5 step 17), not by the body, record it for
        // the linker and suppress body CLOSURE+DECLVAR so a cyclic early
        // import sees the hoisted function and its identity stays stable.
        mod_register_func_decl(mod, fn_name2, inner_idx);
        self.free_reg(func_reg);

        self.register_export(mod, fn_name2, fn_name2, false, 0, false, true)!;
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export class Foo {}
    if (tt == TokenType.CLASS) {
        // class_declaration() consumes `class` + the name itself; ask it to
        // report the bound name via out_name so we can register the export.
        // (The lexer has only a single-token pushback slot, so the old
        // read-name-then-push-both-back approach corrupted the token stream.)
        char[] class_name;
        self.class_declaration(&class_name)!;
        self.register_export(mod, class_name, class_name, false, 0, true, true)!;
        self.match(TokenType.SEMICOLON);
        return;
    }

    // TypeScript `export abstract class Foo {}` — `abstract` is erasable.
    if (self.lexer.ts_mode && tt == TokenType.IDENTIFIER
        && self.check_ts_ident("abstract")) {
        Token abs_tok = self.advance()!;
        if (self.check(TokenType.CLASS)) {
            char[] class_name;
            self.class_declaration(&class_name)!;
            self.register_export(mod, class_name, class_name, false, 0, true, true)!;
            self.match(TokenType.SEMICOLON);
            return;
        }
        self.pushback(abs_tok);
    }

    // export const/let/var x = ...
    if (tt == TokenType.VAR || tt == TokenType.LET || tt == TokenType.CONST) {
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
        ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

        if (!is_lexical) {
            self.has_local_bindings = true;
        }

        // export var/let/const with a destructuring pattern: `export var {a,b}=o`,
        // `export const [x,y]=arr`. Route through the shared destructure
        // machinery, collecting the declared leaf names to register as exports.
        TokenType pat = self.peek_type();
        if (pat == TokenType.LBRACE || pat == TokenType.LBRACKET) {
            char[][MAX_DESTRUCT_BINDS] export_names;
            uint export_names_count = 0;
            self.advance()!;  // consume '{' or '['
            if (pat == TokenType.LBRACE) {
                self.object_destructure(kind, is_lexical, is_const, &export_names[0], &export_names_count)!;
            } else {
                self.array_destructure(kind, is_lexical, is_const, &export_names[0], &export_names_count)!;
            }
            for (uint i = 0; i < export_names_count; i++) {
                self.register_export(mod, export_names[i], export_names[i], false, 0, is_lexical, true)!;
            }
            self.match(TokenType.SEMICOLON);
            return;
        }

        for (;;) {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) {
                return self.fail("reserved word cannot be used as a binding identifier")~;
            }
            // Intern now: an escaped identifier borrows the lexer's shared
            // ident_buf scratch, which the initializer or a later declarator
            // in this same statement will overwrite. declare_var stores this
            // slice into scope_stack, which outlives the current token.
            name_tok.str_value = ((Heap*)self.heap).str_intern(name_tok.str_value).get_data();
            if (self.lexer.ts_mode) {
                self.try_skip_ts_definite_marker()!;
                self.try_skip_ts_type_annotation()!;
            }

            ushort reg;
            if (!is_lexical) {
                ushort? existing = self.resolve_var(name_tok.str_value);
                if (try er = existing) {
                    reg = er;
                } else {
                    reg = self.declare_var(name_tok.str_value, kind);
                }
            } else {
                reg = self.declare_var(name_tok.str_value, kind);
            }

            if (self.match(TokenType.ASSIGN)) {
                ushort val_reg = self.assignment_expr()!;
                if (val_reg != reg) {
                    self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                }
                self.free_reg(val_reg);
            } else {
                if (is_const) return COMPILE_ERROR~;
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }

            uint name_idx = self.add_string_constant(name_tok.str_value);
            self.emit_var_store(reg, name_idx, is_lexical, is_const);
            if (self.is_global) self.free_reg(reg);

            self.register_export(mod, name_tok.str_value, name_tok.str_value, false, 0, is_lexical, true)!;

            if (!self.match(TokenType.COMMA)) break;
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    io::eprintfn("unsupported export form");
    return COMPILE_ERROR~;
}

// ============================================================================
// Catch-clause destructuring (ES2019 §13.15.1)
//
// `catch ([a, b])` and `catch ({x, y})` are syntactically a parameter list
// in the catch clause.  Each binding is block-scoped to the catch block.
// The thrown value is captured by the CATCH opcode into a temp register
// passed in; this function parses the rest of the pattern (the opening
// '[' or '{' has already been consumed) and emits per-binding GETPROP
// extractions from that register, with default-value support.
// ============================================================================

// Array catch pattern. The '[' has already been consumed.
// Uses the iterator protocol on catch_val_reg to extract elements.
// Array catch pattern (`catch ([a, b]) {}`). The '[' has already been consumed.
// Collects via the shared collector, declares each leaf LET-scoped in the catch
// scope, and extracts through emit_destruct_bindings (iterator protocol,
// defaults, rest, IteratorClose), the single destructuring algorithm.
fn void? CompilerContext.compile_catch_array_pattern(&self, ushort catch_val_reg) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_arr_param_binds(binds[..], &count, catch_val_reg, 0xFFFF)!;
    self.emit_catch_pattern(binds[..], count, catch_val_reg)!;
}

// The BoundNames of a destructuring pattern must contain no duplicates
// wherever the pattern introduces LEXICAL bindings: a CatchParameter
// (§14.15.1) and a `let`/`const` ForDeclaration (§14.7.5.1). A `var` pattern
// is exempt, its repeated names all denote the same var binding, so
// `for (var [x, x] of ...)` is legal.
//
// SeenParams already implements exactly this check for FormalParameters, so
// this reuses it rather than growing a second duplicate-name walk.
fn void? CompilerContext.check_pattern_bound_names_unique(&self, DestructBind[] binds, uint count) {
    SeenParams seen;
    seen.declare_destructured(binds, count)!;
}

// Shared tail for both catch patterns: declare LET leaves, then emit.
fn void? CompilerContext.emit_catch_pattern(&self, DestructBind[] binds, uint count, ushort src_reg) {
    self.check_pattern_bound_names_unique(binds, count)!;
    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
        // A destructured leaf is still a CatchParameter BoundName, so the
        // catch block's lexical declarations may not redeclare it (§14.15.1).
        binding_regs[i] = self.declare_var(hs.get_data(), ScopeKind.LET, true);
    }
    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = src_reg;
    }
    self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                DestructStoreMode.DECLARE, true, false);
}

// Object catch pattern (`catch ({e}) {}`). The '{' has already been consumed.
// The caller emits RequireObjectCoercible on catch_val_reg. Collects via the
// shared collector and extracts through emit_destruct_bindings.
fn void? CompilerContext.compile_catch_object_pattern(&self, ushort catch_val_reg) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_obj_param_binds(binds[..], &count, catch_val_reg, 0xFFFF)!;
    self.emit_catch_pattern(binds[..], count, catch_val_reg)!;
}
