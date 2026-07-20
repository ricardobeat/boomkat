module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
import std::io;

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
}

struct CompStarExportEntry {
    uint req_module_idx;
}

struct CompReqModuleEntry {
    char[] module_name;
    void*  resolved;
}

/// Full lexer + compiler-pushback snapshot, used to re-parse a source
/// span (e.g. a for-of/for-in member-expression LHS) fresh on every
/// loop iteration. A bare byte offset isn't enough to resume from: by
/// the time the offset is captured, self.lexer.pos may already sit
/// past a cached lookahead token, so the whole lexer/pushback state
/// must be captured and restored together.
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

const uint COMP_MAX_IMPORTS      = 64;
const uint COMP_MAX_EXPORTS      = 64;
const uint COMP_MAX_STAR_EXPORTS = 16;
const uint COMP_MAX_REQ_MODULES  = 32;
const uint COMP_MAX_FUNC_DECLS   = 128;

/// Layout must match module::FuncDeclEntry.
struct CompFuncDeclEntry {
    char[] name;
    uint   inner_func_idx;
}

/// Compiler-side view of ModuleDef — field layout must match module::ModuleDef.
struct CompModuleDef {
    char[]                              module_name;
    char                                status;
    CompImportEntry[COMP_MAX_IMPORTS]   imports;
    uint                                import_count;
    CompExportEntry[COMP_MAX_EXPORTS]   exports;
    uint                                export_count;
    CompStarExportEntry[COMP_MAX_STAR_EXPORTS] star_exports;
    uint                                star_export_count;
    CompReqModuleEntry[COMP_MAX_REQ_MODULES] req_modules;
    uint                                req_module_count;
    CompFuncDeclEntry[COMP_MAX_FUNC_DECLS] func_decls;
    uint                                func_decl_count;
}

/// Register a top-level module function declaration for eager link-time
/// instantiation (deduplicates by name — a later declaration of the same
/// name replaces the earlier inner_func_idx, mirroring last-wins hoisting).
fn void mod_register_func_decl(CompModuleDef* mod, char[] name, uint inner_func_idx) {
    for (uint i = 0; i < mod.func_decl_count; i++) {
        if (str_eq(mod.func_decls[i].name, name)) {
            mod.func_decls[i].inner_func_idx = inner_func_idx;
            return;
        }
    }
    if (mod.func_decl_count >= COMP_MAX_FUNC_DECLS) return;
    uint idx = mod.func_decl_count;
    mod.func_decls[idx].name = name;
    mod.func_decls[idx].inner_func_idx = inner_func_idx;
    mod.func_decl_count++;
}

/// Register a required module specifier, returning its index (deduplicates).
fn uint mod_register_req_module(CompModuleDef* mod, char[] specifier) {
    for (uint i = 0; i < mod.req_module_count; i++) {
        if (mod.req_modules[i].module_name.len == specifier.len) {
            bool match = true;
            for (usz j = 0; j < specifier.len; j++) {
                if (mod.req_modules[i].module_name[j] != specifier[j]) { match = false; break; }
            }
            if (match) return i;
        }
    }
    if (mod.req_module_count >= COMP_MAX_REQ_MODULES) return 0;
    uint idx = mod.req_module_count;
    mod.req_modules[idx].module_name = specifier;
    mod.req_modules[idx].resolved = null;
    mod.req_module_count++;
    return idx;
}

/// Register an import entry in the module.
fn void mod_register_import(CompModuleDef* mod, char[] local_name, char[] import_name, uint req_idx, bool is_star, bool is_default) {
    if (mod.import_count >= COMP_MAX_IMPORTS) return;
    uint idx = mod.import_count;
    mod.imports[idx].local_name = local_name;
    mod.imports[idx].import_name = import_name;
    mod.imports[idx].req_module_idx = req_idx;
    mod.imports[idx].is_star = is_star;
    mod.imports[idx].is_default = is_default;
    mod.import_count++;
}

/// Register an export entry in the module.
fn void mod_register_export(CompModuleDef* mod, char[] local_name, char[] export_name, bool is_indirect, uint req_idx, bool is_lexical = false) {
    if (mod.export_count >= COMP_MAX_EXPORTS) return;
    uint idx = mod.export_count;
    mod.exports[idx].local_name = local_name;
    mod.exports[idx].export_name = export_name;
    mod.exports[idx].is_indirect = is_indirect;
    mod.exports[idx].req_module_idx = req_idx;
    mod.exports[idx].is_lexical = is_lexical;
    mod.export_count++;
}

/// Register a star export entry in the module.
fn void mod_register_star_export(CompModuleDef* mod, uint req_idx) {
    if (mod.star_export_count >= COMP_MAX_STAR_EXPORTS) return;
    uint idx = mod.star_export_count;
    mod.star_exports[idx].req_module_idx = req_idx;
    mod.star_export_count++;
}

// ============================================================================
// Statement parsing
// ============================================================================

/// Parse and compile a single statement, dispatching on token type.
/// After the statement completes, reclaim_stmt_regs releases any temporaries
/// stranded above the statement's base watermark by non-LIFO free patterns
/// (see reclaim_stmt_regs).
fn void? CompilerContext.statement(&self) {
    ushort stmt_base = self.next_reg;
    TokenType tt = self.peek_type();

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
            // `import(...)` at statement level is a dynamic-import expression
            // statement, not an import declaration. Consume `import` to peek
            // at the following token, then push it back for either path.
            Token import_tok = self.advance()!;
            bool is_dynamic = self.peek_type() == TokenType.LPAREN;
            self.lexer.pushback(import_tok);
            if (is_dynamic) {
                self.expression_statement()!;
            } else {
                self.import_declaration()!;
            }
        }
        case TokenType.EXPORT:
            self.export_declaration()!;
        case TokenType.SEMICOLON:
            // Empty statement
            self.advance()!;
        case TokenType.DEBUGGER:
            self.advance()!;
            self.emit_simple(Opcode.DEBUGGER);
            self.match(TokenType.SEMICOLON);
        default:
            // Check for labels: identifier : statement
            // We consume the identifier and check if the next token is ':'
            if (tt == TokenType.IDENTIFIER) {
                // Consume the identifier token to check what follows
                Token id_tok = self.advance()!;
                if (self.peek_type() == TokenType.COLON) {
                    self.advance()!; // consume ':'
                    self.labeled_statement(id_tok.str_value)!;
                    break;
                }

                // `async function name() {}` — treat as function declaration
                if (self.peek_type() == TokenType.FUNCTION &&
                    id_tok.str_value.len == 5 &&
                    id_tok.str_value[0] == 'a' && id_tok.str_value[1] == 's' &&
                    id_tok.str_value[2] == 'y' && id_tok.str_value[3] == 'n' &&
                    id_tok.str_value[4] == 'c') {
                    // id_tok was `async`; next token is `function`
                    self.function_declaration(true)!;
                    break;
                }

                // Not a label or async function — push the identifier back and fall through
                self.lexer.pushback(id_tok);
            }
            self.expression_statement()!;
    }

    self.reclaim_stmt_regs(stmt_base);
}

/// Check if a name is restricted in strict mode (ES5 §11.6.2.2, ES2024 §13.3.1).
/// The engine is strict-only — there is no non-strict context in which these
/// may appear in a binding position, so we always reject:
///   - `eval`, `arguments` — ES5 strict-only identifiers (§11.6.2.2).
///   - `null`, `true`, `false` — NullLiteral / BooleanLiteral sources; never
///     valid as an IdentifierName in binding position. Lexed as IDENTIFIER
///     with `str_value` matching the literal name (no dedicated token type
///     in this engine), so a post-advance check is the only way to catch
///     `var true = 1` while still allowing property access `obj.true` etc.
///   - `yield`, `await`, `let`, `static`, `implements`, `interface`, `package`,
///     `private`, `protected`, `public` — strict-mode reserved words. Most
///     already come through this path via the lexer's KEYWORDS table
///     (which would deliver a keyword token instead of IDENTIFIER), but
///     `yield` and `await` slip through in non-generator / non-module
///     contexts where the lexer still returns the keyword token, and
///     var_declaration deliberately accepts them. The strict-only engine
///     must always reject.
fn bool is_restricted_name(char[] name) @inline {
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
            if (name[0] == 'a' && name[1] == 'w' && name[2] == 'a' &&
                name[3] == 'i' && name[4] == 't') return true;
            if (name[0] == 'f' && name[1] == 'a' && name[2] == 'l' &&
                name[3] == 's' && name[4] == 'e') return true;
            if (name[0] == 'y' && name[1] == 'i' && name[2] == 'e' &&
                name[3] == 'l' && name[4] == 'd') return true;
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
            // "arguments"
            if (name[0] == 'a' && name[1] == 'r' && name[2] == 'g' &&
                name[3] == 'u' && name[4] == 'm' && name[5] == 'e' &&
                name[6] == 'n' && name[7] == 't' && name[8] == 's') return true;
            break;
        case 10:
            // "implements", "interface"
            if (name[0] == 'i' && name[1] == 'm' && name[2] == 'p' &&
                name[3] == 'l' && name[4] == 'e' && name[5] == 'm' &&
                name[6] == 'e' && name[7] == 'n' && name[8] == 't' &&
                name[9] == 's') return true;
            if (name[0] == 'i' && name[1] == 'n' && name[2] == 't' &&
                name[3] == 'e' && name[4] == 'r' && name[5] == 'f' &&
                name[6] == 'a' && name[7] == 'c' && name[8] == 'e') return true;
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

/// Parse directive prologue statements at the start of a function body or program.
/// Detects "use strict" and enables strict mode if found (ES5 §14.1).
fn void? CompilerContext.parse_directives(&self) {
    while (true) {
        if (!self.check(TokenType.STRING)) {
            break;
        }

        Token str_tok = self.advance()!;

        bool has_semicolon = self.check(TokenType.SEMICOLON);
        bool has_asi = self.lexer.seen_line_term;

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
                    self.is_strict = true;
                    self.saw_use_strict = true;
                    if (self.current_func != null) {
                        self.current_func.flags.is_strict = true;
                    }
                }
            }
        } else {
            self.lexer.pushback(str_tok);
            break;
        }
    }
}

/// Pre-scan tokens in the current block to find all `let`/`const` variable
/// declarations at the top level of the block (brace depth 0, excluding nested
/// blocks).  Saves and restores the lexer state so normal parsing can proceed
/// afterwards.
///
/// Returns the number of variable names found (0 to MAX_PRESCAN_NAMES).
/// Record a prescanned binding name into `spans[idx]`. A plain identifier's
/// str_value points into the source buffer, so it is stored as a (pos, len)
/// span reconstructed later from `lexer.source`. An identifier that contained
/// a unicode escape (`\uXXXX`) is decoded by the lexer into a reused scratch
/// buffer whose contents don't survive the next token — so its bytes are
/// interned to stable storage and kept directly in the span instead.
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
}

/// Reconstruct a prescanned binding name from a NameSpan — either its
/// interned decoded bytes (escaped identifiers) or a slice of the source.
fn char[] CompilerContext.name_span_text(&self, NameSpan span) {
    if (span.name.len > 0) return span.name;
    return self.lexer.source[span.pos..span.pos + span.len - 1];
}

/// True when a `class` following `prev_tt` is a ClassDeclaration (statement
/// position — its BindingIdentifier is a block-scoped lexical binding),
/// rather than a ClassExpression (`x = class C {}`, `f(class C {})`, etc.,
/// where `C` binds only inside the class body). A declaration only begins a
/// Statement, so the token before it is a statement boundary; an expression
/// `class` follows an operator, `=`, `(`, `,`, `return`, `[`, `:`, etc.
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

/// TDZ-initialize top-level let/const declarations at program/eval scope so
/// that accessing or assigning to them before their declaration throws a
/// ReferenceError, matching block scope. Mirrors the INITTZ pass in block().
fn void CompilerContext.hoist_lexical_tdz(&self) {
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    for (uint i = 0; i < n; i++) {
        char[] name = self.name_span_text(spans[i]);
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
    }
}

/// Emit the GlobalDeclarationInstantiation lexName collision checks
/// (ES2015 §15.1.11 step 5) for the top-level `let`/`const`/`class` names.
/// Part of the check prologue that must precede every binding instantiation,
/// so a SyntaxError (existing var/lex binding or restricted global property)
/// throws with no observable side effects. Module top-level lexicals live in
/// the Module Environment Record, which has no such restriction, so this is
/// Script/eval only.
fn void CompilerContext.hoist_lexical_tdz_checks(&self) {
    if (self.is_module) return;
    NameSpan[MAX_PRESCAN_NAMES] spans;
    uint n = self.pre_scan_lexical_decls(&spans, MAX_PRESCAN_NAMES);
    for (uint i = 0; i < n; i++) {
        char[] name = self.name_span_text(spans[i]);
        uint chk_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.CHKGLOBALLEX, 0, chk_idx);
    }
}

/// Each name's position in the source text is stored in `spans` so the
/// caller can reconstruct the `char[]` slice from `lexer.source`.
fn uint CompilerContext.pre_scan_lexical_decls(&self, NameSpan* spans, uint capacity) {
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
    // Previous significant token — used to tell a class DECLARATION from a
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

        // Only collect let/const at the top level of this block (depth 0).
        if (brace_depth == 0 && (tt == TokenType.LET || tt == TokenType.CONST)) {
            // Collect one or more identifier names (comma-separated).
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) {
                    break;
                }
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) {
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
                    break;
                }
                // continue to the next declarator name
            }
            prev_tt = TokenType.SEMICOLON;
            continue;
        }

        // class Name { ... } — collect the binding name. Class declarations
        // are lexically scoped exactly like let/const (ES2015 §14.5.15
        // BlockDeclarationInstantiation), so a `typeof C` before `class C {}`
        // must observe the TDZ, not fall through to "undefined". A class
        // EXPRESSION's name (`var A = class B {}`) is NOT such a binding and
        // must not be collected — distinguished by statement position.
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

/// Pre-scan tokens in the current switch CaseBlock to find all lexically
/// scoped declarations directly inside case/default clauses: `let`/`const`
/// bindings, `class` declarations, and (non-strict-hoisted) `function`/
/// `function*`/`async function` declarations at the top level of the
/// CaseBlock (brace depth 0, excluding nested blocks).
///
/// ES2015 §14.12 CaseBlock has its own lexical scope (BlockDeclarationInstantiation),
/// so all of these names must be TDZ-initialized/scoped to the switch, exactly
/// like block()'s treatment of let/const — this just widens the name set to
/// match everything CaseBlockEvaluation's BlockDeclarationInstantiation collects.
///
/// Saves and restores the lexer state so normal parsing can proceed afterwards.
/// Returns the number of names found (0 to MAX_PRESCAN_NAMES).
fn uint CompilerContext.pre_scan_switch_lexical_decls(&self, NameSpan* spans, uint capacity) {
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
    // position — a FunctionDeclaration or `class` there is a lexical
    // CaseBlock binding. Distinguish that label colon from a ternary
    // `?:` colon by tracking whether an unmatched `?` is still open, and
    // from a colon nested in parens/brackets via paren_depth.
    uint     paren_depth = 0;
    uint     question_depth = 0;

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
                // Closes a ternary — not a case label.
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
        if (tt == TokenType.LET || tt == TokenType.CONST) {
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
                    break;
                }
            }
            prev_tt = TokenType.SEMICOLON;
            continue;
        }

        // class Name { ... } — collect the binding name (declaration only).
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
        // classes — `prev_tt` must be `;`/`{`/`}`. Capture it before the async
        // lookahead consumes prev_tt.
        bool fn_at_stmt_pos = class_is_declaration(prev_tt);

        // async function [*] Name (...) { ... } — only when "async" is
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
                // Not `async function` — this identifier is a plain expression
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

        // function [*] Name (...) { ... } — collect the binding name.
        {
            Token? star_opt = self.lexer.next_token();
            if (catch _err6 = star_opt) {
                break;
            }
            Token star_tok = star_opt;
            Token name_tok;
            if (star_tok.type == TokenType.STAR) {
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

/// Parse a block: { statement* }
/// If `check_directives` is true, checks for "use strict" directive prologue at the start.
fn void? CompilerContext.block(&self, bool check_directives, bool suppress_regex_hint = false) {
    self.expect(TokenType.LBRACE)!;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Push a scope marker so duplicate let/const checks stop at this block boundary.
    self.push_scope_marker();

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

    // Push a new lexical scope for let/const/class/function declarations inside
    // this block. Skip when the block has none — saves an allocation on every
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
    for (uint i = 0; i < num_lex; i++) {
        char[] name = self.name_span_text(lex_spans[i]);
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);

        // Mark the outer scope_stack entry as captured so that the compiler
        // emits GETVAR instead of LDREG for this variable.  Without this,
        // a register-cached value from an outer scope would bypass the TDZ
        // sentinel in the new lex_env.
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

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        self.statement()!;
    }

    self.force_lexical_fn_decl = saved_force_lexical_fn_decl;

    self.expect(TokenType.RBRACE)!;
    // A `}` closing a BlockStatement is a statement boundary: per the
    // ECMAScript lexical grammar, a following `/` starts a
    // RegularExpressionLiteral, not division (see Lexer.note_block_close doc).
    // Function bodies compiled as *expressions* (function expressions, arrow
    // bodies used as call arguments, etc.) are not statement boundaries — the
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

/// Emit the environment store for a declared variable (PUTVAR or PUTLEX/PUTLEX_C).
fn void CompilerContext.emit_var_store(&self, ushort reg, uint name_idx, bool is_lexical, bool is_const) {
    if (is_lexical) {
        if (is_const) {
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)reg, name_idx);
        } else {
            self.emit_a_bc(Opcode.PUTLEX, (uint)reg, name_idx);
        }
    } else {
        // DECLVAR declares the binding in the immediate var_env (function-scoped).
        // PUTVAR (plain assignment) walks the chain to update existing bindings.
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
    }
}

/// Emit a lazy default-value call for destructuring.
/// When the binding value is undefined, evaluates the default thunk and stores
/// the result in bind_reg. Called inside the for-of loop body so the default
/// expression is only ever evaluated at runtime when the value is undefined
/// (per ES2015 §13.3.3.6 IteratorBindingInitialization step 6.b).
fn void CompilerContext.emit_lazy_default(&self, ushort bind_reg, uint func_idx) {
    ushort closure_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);
    ushort call_base = self.alloc_reg();
    ushort this_reg  = self.alloc_reg();
    self.emit_abc(Opcode.LDREG,  (uint)call_base,     (uint)closure_reg, 0);
    self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
    self.emit_abc(Opcode.CALL,   (uint)call_base, (uint)call_base, 0);
    self.emit_abc(Opcode.LDREG,  (uint)bind_reg,  (uint)call_base, 0);
    self.free_reg(this_reg);
    self.free_reg(call_base);
    self.free_reg(closure_reg);
}

/// Parse var/let/const declaration.
fn void? CompilerContext.var_declaration(&self) {
    Token decl_tok = self.advance()!;
    bool is_const = (decl_tok.type == TokenType.CONST);
    bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
    ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

    // var declarations are hoisted to function scope — need env allocation.
    if (!is_lexical) {
        self.has_local_bindings = true;
    }

    // Parse one or more variable declarators
    for (;;) {
        TokenType next = self.peek_type();

        if (next == TokenType.LBRACKET) {
            self.advance()!; // consume '['
            self.array_destructure(kind, is_lexical, is_const)!;
        } else if (next == TokenType.LBRACE) {
            self.advance()!; // consume '{'
            self.object_destructure(kind, is_lexical, is_const)!;
        } else {
            // Per ES2024 §13.3.1, BindingIdentifier is an Identifier or one of
            // `yield`/`await` in non-generator / non-module contexts. We're
            // strict-only but still support script-level `await`/`yield`.
            Token name_tok;
            if (next == TokenType.IDENTIFIER) {
                name_tok = self.advance()!;
            } else if ((next == TokenType.AWAIT && !self.is_module) ||
                       (next == TokenType.YIELD && !self.is_generator)) {
                name_tok = self.advance()!;
            } else {
                return COMPILE_ERROR~;
            }
            if (is_restricted_name(name_tok.str_value)) {
                return self.fail("reserved word cannot be used as a binding identifier")~;
            }
            ushort reg;
            bool already_declared = false;
            if (!is_lexical) {
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
                if (self.is_global && !is_lexical && has_init) {
                    // `var x = <expr>` at global scope is a declaration (already
                    // instantiated by the hoist pass) followed by a plain
                    // assignment. Emit the assignment as PUTVAR — a value-only
                    // update of the existing global binding — rather than
                    // DECLVAR: a global DECLVAR treats an undefined-valued
                    // initializer as a bare re-declaration hoist and (per
                    // CanDeclareGlobalVar) leaves the existing binding untouched,
                    // silently dropping the assigned value when the initializer
                    // happens to evaluate to undefined.
                    self.emit_a_bc(Opcode.PUTVAR, (uint)reg, name_idx);
                } else {
                    self.emit_var_store(reg, name_idx, is_lexical, is_const);
                }
            }

            // At global scope, free the var register and any leaked temporaries
            // from the initializer evaluation.  Global vars use PUTVAR/GETVAR
            // at runtime — the register is only needed briefly as the PUTVAR source.
            // Lexical declarations (let/const) at global scope have their registers
            // managed by pop_scope_to() from the enclosing block() or from the
            // top-level compile() cleanup.
            if (self.is_global) {
                if (!is_lexical) {
                    self.free_reg(reg);
                }
                self.free_regs_to(saved_reg);
            }
        }

        if (!self.match(TokenType.COMMA)) {
            break;
        }
    }

    self.match(TokenType.SEMICOLON);
}



/// Parse if/else statement.
fn void? CompilerContext.if_statement(&self) {
    self.expect(TokenType.IF)!;
    self.expect(TokenType.LPAREN)!;

    // In eval mode, the if-statement always produces a completion value.
    // Per spec §14.6.2: if-false-no-else returns NormalCompletion(undefined);
    // if-with-else returns UpdateEmpty(branchCompletion, undefined).
    // Either way, any prior completion value is replaced — reset to undefined
    // now so an empty or not-taken branch leaves the correct undefined result.
    if (self.eval_mode) {
        self.emit_abc(Opcode.LDUNDEF, (uint)self.eval_acc_reg, 0, 0);
    }

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Emit conditional jump (skip then-branch if false)
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile then-branch
    self.statement()!;

    if (self.match(TokenType.ELSE)) {
        // Emit jump over else-branch
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // Compile else-branch
        self.statement()!;

        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

/// Parse while statement.
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
    // Step 1: Check for while(true) — constant true, skip rotate overhead.
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
            // while(true) — 'true' is lexed as an IDENTIFIER with str_value "true"
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
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs));
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx));
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
    self.statement()!;

    // Save post-body lexer state — outer parser resumes here after return.
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
    // Step 6: cond_label — patch initial JUMP and update continue_target.
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
        // while(true) — unconditional back edge.
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
            self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
        }
        ushort cmp_res = self.alloc_reg();
        self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
        self.free_reg(lhs_reg);
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_res, back));
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
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back));
        self.free_reg(cond_reg);
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

/// Copy a classic for-loop's lexical head bindings into a fresh environment
/// (ES2015 §14.7.4.9 CreatePerIterationEnvironment).  All values must be read
/// before the old environment is popped: after the pop, later bindings in a
/// multi-declarator head are no longer reachable.
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

/// Parse for statement (basic for, for-in, for-of).
fn void? CompilerContext.for_statement(&self) {
    self.expect(TokenType.FOR)!;
    self.expect(TokenType.LPAREN)!;

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
    // At non-global scope: only bindings actually captured by a nested closure need
    // per-iter envs; common non-capturing loops pay no overhead.
    // At global scope: the pre_scan_captures pass is not run (no way to know which
    // names closures capture), so we conservatively enable per-iter for ALL global
    // for-let/for-const loops (the PUSH_LEX/POP_LEX/PUTLEX cost is negligible
    // compared to typical loop bodies, and correct semantics must be preserved).
    // In both cases the env is authoritative: at non-global scope captures use
    // INC_VAR (env-resident); at global scope primary_expr always uses GETVAR
    // and i++ compiles to INC_VAR via a peephole, keeping the env in sync.
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
            if (tok2.type == TokenType.IDENTIFIER && str_eq(tok2.str_value, "of")) {
                // `of` is only a for-of keyword when it is not part of an arrow-function
                // parameter list. For example, `for (async of => {}; ...)` is a plain
                // for-loop whose init is the call expression `async(of => {})`.
                Token of_tok = self.advance()!;
                bool is_arrow = self.peek_type() == TokenType.ARROW;
                self.pushback(of_tok);
                self.pushback(id_tok);
                if (!is_arrow) {
                    // consume the tokens we pushed back; tok2/of_tok is already consumed
                    self.advance()!; // id_tok
                    self.advance()!; // of_tok
                    ushort iter_reg = self.assignment_expr()!;
                    self.expect(TokenType.RPAREN)!;
                    self.emit_forof_loop(id_tok.str_value, iter_reg, saved_scope, saved_reg, false, false, true)!;
                    return;
                }
            } else if (tok2.type == TokenType.IN) {
                self.advance()!;  // consume "in"
                ushort obj_reg = self.assignment_expr()!;
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
    // is a parenthesized identifier — detect it via a three-token lookahead:
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
                    if (pt.type == TokenType.IDENTIFIER && str_eq(pt.str_value, "of")) {
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
            self.emit_forof_loop(paren_id_name, iter_reg, saved_scope, saved_reg, false, false, true)!;
            return;
        }
        if (paren_is_forin) {
            self.advance()!; // consume '('
            self.advance()!; // consume identifier
            self.advance()!; // consume ')'
            self.advance()!; // consume 'in'
            ushort obj_reg = self.assignment_expr()!;
            self.expect(TokenType.RPAREN)!;
            self.emit_bare_forin_loop(paren_id_name, obj_reg, saved_scope, saved_reg)!;
            return;
        }
    }

    // Check for bare for-of/for-in with a member-expression LHS:
    // for (obj.prop of expr) / for (obj[key] in expr). Per ES2015
    // §13.7.5.1 the head's AssignmentExpression may be any valid
    // assignment target, not just an identifier — member expressions
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
        // by the bare-destructuring branch below — member_expr cannot
        // parse a `[...]`/`{...}` pattern but would still emit code for
        // any elements (e.g. GETVAR for a bare `[x]` element) that
        // survives the lexer restore, leaving a stray GETVAR in the
        // bytecode before the real destructure.  Skip member_expr here
        // when LHS opens with `[` or `{`.
        ForLhsSnapshot lhs_snap = self.save_lhs_snapshot();
        ushort saved_next_reg = self.next_reg;

        bool is_member_head = false;
        bool head_is_of = false;

        if (try mreg = self.member_expr()) {
            if (self.last_was_member) {
                self.free_reg(self.last_member_prop_reg);
                self.free_reg(self.last_member_obj_reg);
                self.free_reg(mreg);
                if (try tok3 = self.lexer.peek()) {
                    if (tok3.type == TokenType.IDENTIFIER && str_eq(tok3.str_value, "of")) {
                        is_member_head = true;
                        head_is_of = true;
                    } else if (tok3.type == TokenType.IN) {
                        is_member_head = true;
                        head_is_of = false;
                    }
                }
            }
        }

        // Restore lexer + register state; the LHS is re-parsed from
        // source once per iteration (see emit_forof_loop_member/
        // emit_forin_loop_member), so nothing from this speculative
        // parse should be kept.
        self.restore_lhs_snapshot(lhs_snap);
        self.next_reg = saved_next_reg;

        if (is_member_head) {
            // Re-consume the LHS for real (the speculative parse above was
            // fully unwound). member_expr() naturally stops right before
            // `of`/`in` since neither token continues a member expression.
            self.member_expr()!;
            self.free_reg(self.last_member_prop_reg);
            self.free_reg(self.last_member_obj_reg);
            self.advance()!;  // consume "of" or "in"

            if (head_is_of) {
                ushort iter_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;
                self.emit_forof_loop_member(lhs_snap, iter_reg, saved_scope, saved_reg)!;
            } else {
                ushort obj_reg = self.assignment_expr()!;
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
    // — any speculative compile of the LHS would leak GETVAR/INC/etc.
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
            if (pt.type == TokenType.IDENTIFIER && str_eq(pt.str_value, "of")) {
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
                self.emit_bare_forof_destruct_loop(is_array_pattern, saved_scope, saved_reg)!;
            } else {
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
                if (pt.type == TokenType.IDENTIFIER && str_eq(pt.str_value, "of")) {
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

                // ── Parse the destructuring pattern inline ──
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
                for (uint i = 0; i < bind_count; i++) {
                    if (dbinds[i].is_synthetic) continue;
                    HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
                    ushort dreg = self.declare_var(hs.get_data(), decl_kind);
                    dbinding_regs[i] = dreg;
                }

                // Consume "of" (contextual keyword - lexed as IDENTIFIER)
                {
                    Token of_tok = self.expect(TokenType.IDENTIFIER)!;
                    if (!str_eq(of_tok.str_value, "of")) {
                        return COMPILE_ERROR~;
                    }
                }

                // ── TDZ scope for head bindings (spec §13.7.5.12) ──
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
                        // emits GETVAR instead of LDREG — prevents bypassing
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

                // Pop the TDZ scope — the head binding references are now
                // resolved against the outer scope for the iterator protocol.
                if (has_head_tdz) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }

                self.expect(TokenType.RPAREN)!;

                // ── Outer iterator protocol setup ──
                ushort sym_reg = self.alloc_reg();
                self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

                ushort iter_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

                ushort symbol_val_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
                self.free_reg(iter_key_reg);
                self.free_reg(sym_reg);

                ushort method_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
                self.free_reg(symbol_val_reg);

                ushort this_slot = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
                self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
                self.free_reg(this_slot);

                ushort next_reg = self.alloc_reg();
                ushort next_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
                self.free_reg(next_key_reg);

                // Persistent holder for the yielded value, allocated BELOW the
                // callee window so it survives the outer .next() CALL frame
                // overlay.  When the source is a generator, its suspended frame
                // occupies the sliding window at/above callee_reg; running the
                // inner (nested) destructuring's iterator protocol there would
                // otherwise clobber a value held in a register inside that
                // window on the next resume.  We copy the extracted value here,
                // free the above-callee per-iteration temps, then destructure
                // this holder — mirroring how the plain for-of copies to its
                // loop variable and frees temps before the body.
                ushort val_holder = self.alloc_persistent_reg();

                ushort callee_reg = self.alloc_reg();
                ushort callee_this_reg = self.alloc_reg();

                // ── Loop ──
                // Per-iteration lexical environment (ES2015 §14.7.5.6):
                // For let/const destructuring, each iteration must create a fresh
                // declarative environment so closures in the body capture distinct
                // bindings per iteration.  INITTZ marks each binding as TDZ before
                // the destructuring store writes the actual value.
                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);
                self.loop_stack[self.loop_depth - 1].iter_close_reg = (int)method_reg;

                bool has_lex_destr = is_lexical && bind_count > 0;
                if (has_lex_destr) {
                    self.emit_simple(Opcode.PUSH_LEX);
                    self.cur_lex_depth++;
                    // TDZ-initialize each head binding in the fresh per-iter env.
                    for (uint i = 0; i < bind_count; i++) {
                        if (dbinds[i].is_synthetic) continue;
                        HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
                        uint name_idx = self.add_string_constant(hs.get_data());
                        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);
                    }
                }

                // Reload callee/this from the below-window next_reg/method_reg
                // each iteration: a generator source (or any iterator that
                // re-dispatches) resuming through the nested destructuring can
                // overwrite the callee window, so refresh it before every
                // .next() — mirrors the plain for-of loop.
                self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
                self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

                ushort result_reg = self.alloc_reg();
                self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

                ushort done_key_reg = self.alloc_reg();
                ushort done_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
                uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

                ushort value_key_reg = self.alloc_reg();
                ushort val_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

                // Move the value into the below-callee holder, then release the
                // above-callee protocol temps so the nested destructuring below
                // runs at a watermark that does not overlap the outer iterator's
                // (possibly generator) call frame.
                self.emit_abc(Opcode.LDREG, (uint)val_holder, (uint)val_reg, 0);
                self.free_reg(val_reg);
                self.free_reg(value_key_reg);
                self.free_reg(done_reg);
                self.free_reg(done_key_reg);
                self.free_reg(result_reg);

                // ── IteratorClose-on-error guard (ES2022 §14.7.5.6) ──
                // Wrap the destructuring + body in TRY/CATCH so that any abrupt
                // completion (throw from destructuring, body, etc.) calls
                // IteratorClose on the for-of iterator before propagating.
                // B=1: throw completion — suppress errors from .return access/call.
                uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
                uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

                // ── Destructure the yielded value via the shared emitter ──
                // RequireObjectCoercible (ES2015 §13.3.3.6): an object pattern
                // rejects a null/undefined source even when empty, matching the
                // object_destructure / object_destructure_assign wrappers.
                if (!is_array_pattern) {
                    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)val_holder, 0, 0);
                }
                // Point every top-level bind at the persistent value holder and
                // run the same emit_destruct_bindings used by declarations,
                // parameters, and assignment targets (iterator protocol, defaults,
                // IteratorClose, done-latching all handled there).
                for (uint bi = 0; bi < bind_count; bi++) {
                    if (dbinds[bi].parent_idx == 0xFFFF) dbinds[bi].arg_idx = val_holder;
                }
                self.emit_destruct_bindings(dbinds[..], bind_count, dgroup_regs[..], dbinding_regs[..],
                                            DestructStoreMode.DECLARE, is_lexical, is_const);

                self.statement()!;

                // Normal path: end the try region and jump over the catch block.
                self.emit_simple(Opcode.ENDTRY);
                uint jump_over = self.emit_jump(Opcode.JUMP);

                // Catch block: called on any abrupt completion (throw, etc.).
                uint catch_target = self.code_count;
                ushort err_reg = self.alloc_reg();
                self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);

                // Unwind per-iter env if present, then call IteratorClose.
                if (has_lex_destr) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }
                self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 1, 0);

                // Re-throw the original error.
                self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
                self.free_reg(err_reg);

                // Patch the jump to skip the catch block.
                self.patch_jump(jump_over);

                // Patch the TRY instruction: flags=1 (catch only), BC=offset to catch block.
                uint catch_off = catch_target - iter_try_addr;
                self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
                self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

                // Per-iter env epilogue: pop before the back-edge.
                // For continue: the continue statement's own POP_LEX unwinds
                // cur_lex_depth back to the per-iter level, so continue lands
                // on the JUMP below rather than double-popping.
                if (has_lex_destr) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }

                self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;

                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                // Exit path (done=true): pop per-iter env pushed at loop_start,
                // then emit the exhaustion ITER_CLOSE before pop_loop so
                // break-patch targets land after this.
                if (has_lex_destr) {
                    self.emit_simple(Opcode.POP_LEX);
                    self.cur_lex_depth--;
                }
                self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 0, 0);
                self.pop_loop();

                self.free_reg(callee_this_reg);
                self.free_reg(callee_reg);
                self.free_reg(val_holder);
                self.free_reg(next_reg);
                self.free_reg(method_reg);
                self.free_reg(iter_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            } else if (is_forin_destr) {
                // for-in with destructuring: for (let {x, y} in obj) or for (let [a, b] in obj)
                bool is_array_pattern = (after_decl == TokenType.LBRACKET);
                ushort obj_reg = 0;

                // ── Collect the pattern via the shared param collectors ──
                DestructBind[MAX_DESTRUCT_BINDS] fdbinds;
                uint fdcount = 0;
                self.advance()!; // consume '[' or '{'
                if (is_array_pattern) {
                    self.collect_arr_param_binds(fdbinds[..], &fdcount, 0, 0xFFFF)!;
                } else {
                    self.collect_obj_param_binds(fdbinds[..], &fdcount, 0, 0xFFFF)!;
                }
                ushort[MAX_DESTRUCT_BINDS] fdgroup_regs;
                ushort[MAX_DESTRUCT_BINDS] fdbinding_regs;
                for (uint i = 0; i < fdcount; i++) { fdgroup_regs[i] = 0xFFFF; fdbinding_regs[i] = 0xFFFF; }
                for (uint i = 0; i < fdcount; i++) {
                    if (fdbinds[i].is_synthetic) continue;
                    HString* hs = (HString*)self.constants[fdbinds[i].name_idx].get_heapptr();
                    fdbinding_regs[i] = self.declare_var(hs.get_data(), decl_kind);
                }

                self.expect(TokenType.IN)!;

                obj_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                }

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


                self.statement()!;

                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                }

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            } else {
                // Standard for-loop with destructuring init: for (var [a,b] = ...; ...; ...)
                // A lexical head owns one environment for the whole loop.  The
                // destructuring helpers emit PUTLEX/PUTLEX_C while evaluating the
                // initializer, so install that environment before they run (the
                // common exit path below emits the matching POP_LEX).
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
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
                        ushort extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                        if (self.match(TokenType.ASSIGN)) {
                            ushort extra_val = self.assignment_expr()!;
                            if (extra_val != extra_reg) {
                                self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                            }
                            self.free_reg(extra_val);
                        } else {
                            self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                        }
                        uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                        self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                    }
                }

                self.expect(TokenType.SEMICOLON)!;
            }
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;

            // Check for "in" (for-in) or "of" (for-of)
            if (self.peek_type() == TokenType.IN) {
                // for (let/const/var x in obj) { ... }
                self.advance()!;  // consume 'in'
                // Declare the for-in variable so let/const semantics
                // (write-protection, TDZ, duplicate detection) are enforced.
                // For lexical bindings, declare_var pushes a scope_stack entry
                // so the body can resolve the name via the scope chain.
                ushort iter_var = self.declare_var(name_tok.str_value, decl_kind);
                ushort obj_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                // For let/const, push a new lexical environment so the loop
                // variable is block-scoped (not visible outside the loop) and
                // closures inside the body capture from this lex_env.
                if (is_lexical) {
                    self.emit_simple(Opcode.PUSH_LEX);
                }

                // Emit INITFOR to set up the iterator
                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                // Emit NEXTFOR: iter_var = next key, B = has_next
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);
                // Sync the for-in variable to the environment
                uint forin_name_idx = self.add_string_constant(name_tok.str_value);
                self.emit_var_store(iter_var, forin_name_idx, is_lexical, is_const);
                // No reload needed: DECLVAR/PUTLEX/PUTLEX_C do not clear the source
                // register, so iter_var still holds the current key after the store.

                // If no more keys, exit
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                // Compile body
                self.statement()!;

                // Jump back to loop start
                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                // Pop the lexical scope for let/const, removing the
                // block-scoped binding from the VM's lex_env chain.
                if (is_lexical) {
                    self.emit_simple(Opcode.POP_LEX);
                }

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            }
            // Check for "of" (for-of) — contextual keyword, not a reserved word
            if (try tok = self.lexer.peek()) {
                if (tok.type == TokenType.IDENTIFIER && str_eq(tok.str_value, "of")) {
                    self.advance()!;  // consume "of"
                    // ── TDZ scope for head binding (spec §13.7.5.12) ──
                    // Before evaluating the RHS, a TDZ environment is created
                    // for the head name so that typeof/name access inside the
                    // RHS throws ReferenceError (temporal dead zone).
                    if (is_lexical) {
                        self.emit_simple(Opcode.PUSH_LEX);
                        self.cur_lex_depth++;
                        self.emit_a_bc(Opcode.INITTZ, 0, self.add_string_constant(name_tok.str_value));
                        // Mark the outer scope entry as captured so the compiler
                        // emits GETVAR instead of LDREG — without this, a
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
                    self.emit_forof_loop(name_tok.str_value, iter_reg, saved_scope, saved_reg, is_lexical, is_const, false)!;
                    return;
                }
            }

            // Standard for loop: we already consumed the decl keyword and identifier
            // Declare the variable and optionally initialize
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
            has_for_var = !is_lexical && !self.is_global
                       && !self.is_captured_name(name_tok.str_value);
            for_var_reg = var_reg;
            for_var_name_idx = self.add_string_constant(name_tok.str_value);
            // Collect per-iter binding: a let/const binding needs a fresh env each
            // iteration so closures in different iterations capture distinct values.
            // At non-global scope only captured bindings trigger per-iter (perf guard).
            // At global scope all let/const bindings trigger per-iter conservatively
            // (capture analysis is not run for global scripts).
            if (is_lexical && (self.is_global || self.is_captured_name(name_tok.str_value))) {
                needs_periterenv = true;
            }
            if (is_lexical && periterenv_count < 8) {
                periterenv_names[periterenv_count] = name_tok.str_value;
                periterenv_name_idxs[periterenv_count] = for_var_name_idx;
                periterenv_is_const[periterenv_count] = is_const;
                periterenv_count++;
            }
            if (is_lexical) { self.emit_simple(Opcode.PUSH_LEX); }
            if (self.match(TokenType.ASSIGN)) {
                ushort init_val = self.assignment_expr()!;
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
                    ushort extra_reg;
                    if (!is_lexical) {
                        ushort? existing2 = self.resolve_var(extra_name.str_value);
                        if (try er2 = existing2) {
                            extra_reg = er2;
                        } else {
                            extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                        }
                    } else {
                        extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                    }
                    if (self.match(TokenType.ASSIGN)) {
                        ushort extra_val = self.assignment_expr()!;
                        if (extra_val != extra_reg) {
                            self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                        }
                        self.free_reg(extra_val);
                    } else {
                        self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                    }
                    uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                    self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                    // Track extra let/const bindings for per-iter env prologue.
                    if (is_lexical && (self.is_global || self.is_captured_name(extra_name.str_value))) {
                        needs_periterenv = true;
                    }
                    if (is_lexical && periterenv_count < 8) {
                        periterenv_names[periterenv_count] = extra_name.str_value;
                        periterenv_name_idxs[periterenv_count] = extra_name_idx;
                        periterenv_is_const[periterenv_count] = is_const;
                        periterenv_count++;
                    }
                }
            }

            self.expect(TokenType.SEMICOLON)!;
        }
    } else if (next_tt != TokenType.SEMICOLON) {
        // Expression init
        ushort init_reg = self.expression()!;
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
        // Empty init
        self.expect(TokenType.SEMICOLON)!;
    }

    // --- Rotated for-loop layout ---
    // Avoid running the condition before the first body iteration by rotating:
    //
    //   JUMP → cond_label            (executed once; provides zero-iteration check)
    //   body_label:
    //     <body>
    //   incr_label:                  ← continue targets here
    //     <increment>
    //   cond_label:
    //     <condition>  (IF_TRUE → body_label  — back edge)
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
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)pinned_rhs_reg, int_rhs));
        } else {
            uint rhs_const_idx = self.add_number_constant(simple_cond_rhs);
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)pinned_rhs_reg, rhs_const_idx));
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

    self.statement()!;

    // Save the lexer state after the body — this is where the outer parser
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
    // Step 6: incr_label — CreatePerIterationEnvironment, then compile increment.
    // ----------------------------------------------------------------
    // Per-iteration environment (ES2015 §14.7.4.2 CreatePerIterationEnvironment):
    // The spec runs CreatePerIterationEnvironment *after* the body and *before*
    // the increment on every iteration (ForBodyEvaluation step 3.e). We emit the
    // env-cycling code here at incr_label so that `continue` also triggers it,
    // keeping the semantics correct: GETVAR reads the binding's current value (the
    // env is authoritative — INC_VAR and PUTVAR both update it), then POP_LEX/
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
        // saved_reg so the increment and condition compile into fresh temporaries
        // above all live locals, not into registers that belong to live variables.
        if (self.next_reg < saved_reg) {
            self.next_reg = saved_reg;
        }
        ushort incr_reg = self.expression()!;
        self.free_reg(incr_reg);
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
    // Step 7: cond_label — patch initial JUMP, compile condition with IF_TRUE back edge.
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
            // Mirror primary_expr: at global scope, all identifiers go through GETVAR
            // (registers are not kept in sync with the env by the body). resolve_var is
            // only safe when the body also uses the register directly (non-global scope).
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
                self.emit_a_bc(Opcode.GETVAR, (uint)lhs_reg, name_idx2);
            }
            ushort cmp_res = self.alloc_reg();
            self.emit_abc(simple_cond_op, (uint)cmp_res, (uint)lhs_reg, (uint)pinned_rhs_reg);
            self.free_reg(lhs_reg);
            int back = (int)body_label - (int)self.code_count - 1;
            self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_res, back));
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
            // register still owned by a live variable such as the for-init var.
            if (self.next_reg < saved_reg) {
                self.next_reg = saved_reg;
            }
            ushort cond_reg = self.expression()!;
            self.expect(TokenType.SEMICOLON)!;
            int back = (int)body_label - (int)self.code_count - 1;
            self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back));
            self.free_reg(cond_reg);
        }
    } else {
        // for(;;) — unconditional back edge
        int back = (int)body_label - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, back));
    }

    // exit: pop_loop patches all break jumps to current position.
    self.pop_loop();
    if (is_lexical) { self.emit_simple(Opcode.POP_LEX); }

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

/// Capture the full lexer + compiler-pushback state for later replay
/// via restore_lhs_snapshot. See ForLhsSnapshot for why this must be
/// the whole state, not just a byte offset.
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

/// Restore a snapshot captured by save_lhs_snapshot.
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

/// Emit a bare for-in loop whose LHS is a plain identifier with no
/// declaration keyword: `for (x in obj) { ... }`. Mirrors the
/// `var`/`let`/`const` for-in path but stores each key via PUTVAR
/// against an existing binding instead of declaring a new one.
fn void? CompilerContext.emit_bare_forin_loop(&self, char[] var_name, ushort obj_reg, uint saved_scope, ushort saved_reg) {
    uint name_idx = self.add_string_constant(var_name);
    ushort iter_var = self.alloc_reg();

    ushort iter_state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);
    self.emit_a_bc(Opcode.PUTVAR, (uint)iter_var, name_idx);

    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);

    self.statement()!;

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

/// Emit a for-of loop with a bare destructuring pattern LHS:
/// `for ([a, b] of arr) { ... }` or `for ({x, y} of arr) { ... }`.
/// Bindings are VAR-scoped and persist across iterations (no per-iter
/// block scope). The '[' or '{' has NOT been consumed on entry.
fn void? CompilerContext.emit_bare_forof_destruct_loop(&self, bool is_array_pattern, uint saved_scope, ushort saved_reg) {
    // ── Collect the assignment pattern via the shared collectors ──
    // Bare for-of (`for ([a] of ...)` / `for ({x} of ...)`) assigns to existing
    // lvalues, so this uses the assignment collectors (full LHS grammar) and
    // emits via emit_destruct_bindings(ASSIGN_TARGET) — one algorithm shared
    // with array/object destructuring assignment.
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
        if (!str_eq(of_tok.str_value, "of")) {
            return COMPILE_ERROR~;
        }
    }

    ushort iter_reg = self.assignment_expr()!;
    self.expect(TokenType.RPAREN)!;

    // ── Outer iterator protocol setup ──
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));
    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);
    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);

    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);

    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);

    ushort next_reg = self.alloc_reg();
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);

    // Persistent value holder below the callee window (see the let/const
    // for-of destructuring path for the rationale): a generator source resuming
    // through the nested destructuring can clobber registers inside the .next()
    // call frame, so the yielded value is copied here — below callee_reg — and
    // the above-callee temps are freed before the destructuring runs.
    ushort val_holder = self.alloc_persistent_reg();

    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();

    // ── Loop ──
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);
    self.loop_stack[self.loop_depth - 1].iter_close_reg = (int)method_reg;

    // Reload callee/this from the below-window next_reg/method_reg every
    // iteration so a generator (or re-dispatching iterator) that overwrote the
    // callee window during the previous iteration's destructuring is healed.
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    ushort value_key_reg = self.alloc_reg();
    ushort val_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);
    // Move value below the callee window, then release the above-callee temps.
    self.emit_abc(Opcode.LDREG, (uint)val_holder, (uint)val_reg, 0);
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // ── IteratorClose-on-error guard (ES2022 §14.7.5.6) ──
    // Wrap the destructuring + body in TRY/CATCH so that any abrupt completion
    // (throw from destructuring, body, etc.) calls IteratorClose on the
    // outer for-of iterator before propagating.  B=1: throw completion —
    // suppress errors from .return access/call (the original throw takes
    // precedence, per ES2022 §7.4.6 steps 6,8).
    uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

    // ── Destructure the yielded value via the shared emitter ──
    // RequireObjectCoercible for object patterns (rejects null/undefined even
    // when empty); array patterns open the iterator inside the emitter.
    if (!is_array_pattern) {
        self.emit_abc(Opcode.REQUIRE_OBJ, (uint)val_holder, 0, 0);
    }
    for (uint bi = 0; bi < dcount; bi++) {
        if (dbinds[bi].parent_idx == 0xFFFF) dbinds[bi].arg_idx = val_holder;
    }
    if (dcount > 0) {
        self.emit_destruct_bindings(dbinds[..], dcount, dgroup_regs[..], dbinding_regs[..],
                                    DestructStoreMode.ASSIGN_TARGET);
    } else if (is_array_pattern) {
        // Empty array pattern `for ([] of ...)`: still GetIterator(value) and
        // immediately IteratorClose it per DestructuringAssignmentEvaluation.
        self.emit_empty_array_iter(val_holder);
    }

    // Compile body
    self.statement()!;

    // Normal path: end the try region and jump over the catch block.
    self.emit_simple(Opcode.ENDTRY);
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // Catch block: called on any abrupt completion (throw, etc.).
    uint catch_target = self.code_count;
    ushort err_reg = self.alloc_reg();
    self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);

    // Call IteratorClose (throw variant — suppress .return errors).
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 1, 0);

    // Re-throw the original error.
    self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
    self.free_reg(err_reg);

    // Patch the jump to skip the catch block.
    self.patch_jump(jump_over);

    // Patch the TRY instruction: flags=1 (catch only), BC=offset to catch block.
    uint catch_off = catch_target - iter_try_addr;
    self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
    self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 0, 0);
    self.pop_loop();

    self.free_reg(callee_this_reg);
    self.free_reg(callee_reg);
    self.free_reg(val_holder);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.free_reg(iter_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Emit a for-in loop with a bare destructuring pattern LHS:
/// `for ([a, b] in obj) { ... }` or `for ({x, y} in obj) { ... }`.
/// Bindings are VAR-scoped. The '[' or '{' has NOT been consumed.
fn void? CompilerContext.emit_bare_forin_destruct_loop(&self, bool is_array_pattern, uint saved_scope, ushort saved_reg) {
    // Collect the pattern via the shared param collectors (VAR-declared leaves),
    // then extract each enumerated key through emit_destruct_bindings below.
    DestructBind[MAX_DESTRUCT_BINDS] dbinds;
    uint dcount = 0;
    self.advance()!; // consume '[' or '{'
    if (is_array_pattern) {
        self.collect_arr_param_binds(dbinds[..], &dcount, 0, 0xFFFF)!;
    } else {
        self.collect_obj_param_binds(dbinds[..], &dcount, 0, 0xFFFF)!;
    }
    ushort[MAX_DESTRUCT_BINDS] dgroup_regs;
    ushort[MAX_DESTRUCT_BINDS] dbinding_regs;
    for (uint i = 0; i < dcount; i++) { dgroup_regs[i] = 0xFFFF; dbinding_regs[i] = 0xFFFF; }
    for (uint i = 0; i < dcount; i++) {
        if (dbinds[i].is_synthetic) continue;
        HString* hs = (HString*)self.constants[dbinds[i].name_idx].get_heapptr();
        dbinding_regs[i] = self.declare_var(hs.get_data(), ScopeKind.VAR);
    }

    self.expect(TokenType.IN)!;
    ushort obj_reg = self.assignment_expr()!;
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

    // Destructure each enumerated key via the shared emitter (DECLARE, VAR).
    if (!is_array_pattern) {
        self.emit_abc(Opcode.REQUIRE_OBJ, (uint)key_reg, 0, 0);
    }
    for (uint bi = 0; bi < dcount; bi++) {
        if (dbinds[bi].parent_idx == 0xFFFF) dbinds[bi].arg_idx = key_reg;
    }
    if (dcount > 0) {
        self.emit_destruct_bindings(dbinds[..], dcount, dgroup_regs[..], dbinding_regs[..],
                                    DestructStoreMode.DECLARE, false, false);
    }

    self.statement()!;

    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    self.free_reg(iter_state);
    self.free_reg(obj_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Emit a for-of loop whose head LHS is a member expression, e.g.
/// `for (obj.prop of arr) { ... }` (ES2015 §13.7.5.1: the head's
/// AssignmentExpression may be any valid assignment target, not just
/// an identifier). The LHS is re-parsed from source and re-compiled
/// fresh at the top of every iteration (right before the body), which
/// gives correct per-iteration re-evaluation of the member base per
/// spec, reusing the same PUTPROP path normal assignment uses.
fn void? CompilerContext.emit_forof_loop_member(&self, ForLhsSnapshot lhs_snap, ushort iter_reg, uint saved_scope, ushort saved_reg) {
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));
    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);
    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);

    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);

    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);

    ushort next_reg = self.alloc_reg();
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);

    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

    // Validate .next() result is an Object (ES2022 §14.7.5.6 step 3.b).
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

    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // ── IteratorClose-on-error guard (ES2022 §14.7.5.6) ──
    // Wrap the assignment + body in TRY/CATCH so that any abrupt completion
    // calls IteratorClose before propagating.
    uint iter_try_addr  = self.emit_a_bc(Opcode.TRY, 0, 0);
    uint iter_jump_slot = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Re-parse and re-compile the member LHS from source, then store the
    // per-iteration value into it via PUTPROP. This must happen after the
    // iterator-result registers above are freed (their reg slots are
    // reused by the LHS compile) and before the body statement.
    self.emit_member_lhs_store(lhs_snap, val_reg)!;

    self.statement()!;

    // Normal path: end the try region and jump over the catch block.
    self.emit_simple(Opcode.ENDTRY);
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // Catch block: called on any abrupt completion (throw, etc.).
    uint catch_target = self.code_count;
    ushort err_reg = self.alloc_reg();
    self.emit_abc(Opcode.CATCH, (uint)err_reg, 0, 0);

    // Call IteratorClose (throw variant — suppress .return errors).
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 1, 0);

    // Re-throw the original error.
    self.emit_abc(Opcode.THROW, (uint)err_reg, 0, 0);
    self.free_reg(err_reg);

    // Patch the jump to skip the catch block.
    self.patch_jump(jump_over);

    // Patch the TRY instruction: flags=1 (catch only), BC=offset to catch block.
    uint catch_off = catch_target - iter_try_addr;
    self.code[iter_try_addr] = bytecode::make_a_bc(Opcode.TRY, 1, catch_off);
    self.code[iter_jump_slot] = bytecode::make_a_bc(Opcode.NOP, 0, 0);

    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.emit_abc(Opcode.ITER_CLOSE, (uint)method_reg, 0, 0);
    self.pop_loop();

    self.free_reg(callee_this_reg);
    self.free_reg(callee_reg);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Emit a for-in loop whose head LHS is a member expression, e.g.
/// `for (obj.prop in x) { ... }`. Same re-parse-per-iteration strategy
/// as emit_forof_loop_member.
fn void? CompilerContext.emit_forin_loop_member(&self, ForLhsSnapshot lhs_snap, ushort obj_reg, uint saved_scope, ushort saved_reg) {
    ushort key_reg = self.alloc_reg();

    ushort iter_state = self.alloc_reg();
    self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    ushort has_next = self.alloc_reg();
    self.emit_abc(Opcode.NEXTFOR, (uint)key_reg, (uint)has_next, (uint)iter_state);

    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
    self.free_reg(has_next);

    self.emit_member_lhs_store(lhs_snap, key_reg)!;

    self.statement()!;

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

/// Re-parse a member-expression LHS from a saved lexer snapshot and
/// emit `<lhs> = val_reg` via PUTPROP. Used by the for-of/for-in
/// member-LHS loops to re-evaluate the assignment target fresh each
/// iteration (ES2015 §13.7.5.13 ForIn/OfBodyEvaluation: the reference
/// is (re-)resolved every iteration for non-declaration LHS forms).
fn void? CompilerContext.emit_member_lhs_store(&self, ForLhsSnapshot lhs_snap, ushort val_reg) {
    ForLhsSnapshot resume_snap = self.save_lhs_snapshot();

    self.restore_lhs_snapshot(lhs_snap);

    ushort mreg = self.member_expr()!;
    if (self.last_was_member) {
        self.free_reg(mreg);
        self.emit_abc(Opcode.PUTPROP, (uint)self.last_member_obj_reg, (uint)self.last_member_prop_reg, (uint)val_reg);
        self.free_reg(self.last_member_prop_reg);
        self.free_reg(self.last_member_obj_reg);
    }

    self.restore_lhs_snapshot(resume_snap);
}

/// Parse do-while statement.
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
    self.statement()!;

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
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back_offset));
    self.free_reg(cond_reg);

    self.pop_loop();
}

/// Parse return statement.
/// Emit ITER_CLOSE for every enclosing for-of loop, innermost first.
/// A return exits all loops in the function, so each loop's iterator must be
/// closed (§14.7.5.7 — abrupt loop completions call IteratorClose).
fn void CompilerContext.emit_return_iter_closes(&self) {
    for (int li = (int)self.loop_depth - 1; li >= 0; li--) {
        if (self.loop_stack[li].iter_close_reg >= 0) {
            self.emit_abc(Opcode.ITER_CLOSE, (uint)self.loop_stack[li].iter_close_reg, 0, 0);
        }
    }
}

fn void? CompilerContext.return_statement(&self) {
    self.expect(TokenType.RETURN)!;

    // ES2015 §14.9.1: `return` is only valid inside a FunctionBody — a
    // top-level Script or eval-code Program has no function to return from.
    // A nested function body gets its own CompilerContext (is_global always
    // false there), so this only fires for genuinely top-level `return`.
    if (self.is_global) {
        return COMPILE_ERROR~;
    }

    // Check if there's a return value (not a semicolon or end-of-statement)
    // A line terminator between return and the expression causes ASI (ES5 §12.9)
    TokenType next = self.peek_type();
    if (next == TokenType.SEMICOLON || next == TokenType.RBRACE ||
        next == TokenType.EOF_TOKEN || self.lexer.seen_line_term) {
        self.emit_return_iter_closes();
        self.emit_simple((self.is_generator && !self.is_async) ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    } else {
        ushort val_reg = self.expression()!;
        // IteratorClose runs after the return value is evaluated but before
        // the frame unwinds (§14.7.5.7 loop completion propagation).
        self.emit_return_iter_closes();
        self.emit_abc((self.is_generator && !self.is_async) ? Opcode.RET_GEN : Opcode.RET, (uint)val_reg, 0, 0);
        // Note: do NOT free_reg(val_reg) here.  The return value register may
        // be a live local variable (e.g. `return i` inside a for-loop body).
        // Calling free_reg would let the allocator reuse it for subsequent
        // code (the loop increment/condition), clobbering the variable.
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse throw statement.
fn void? CompilerContext.throw_statement(&self) {
    self.expect(TokenType.THROW)!;

    ushort val_reg = self.expression()!;
    self.emit_abc(Opcode.THROW, (uint)val_reg, 0, 0);
    // Note: do NOT free_reg(val_reg) here, same reason as return_statement.

    self.match(TokenType.SEMICOLON);
}

/// Parse try/catch/finally statement.
///
/// Bytecode layout:
///   TRY A=flags, BC=catch_offset     — A bit0=catch, bit1=finally
///   NOP A=0,    BC=finally_offset    — jump slot (0 if no finally)
///   <try block>
///   ENDTRY
///   JUMP -> finally_or_after
///   [CATCH rX  — at try_addr + catch_offset]
///   [<catch block>]
///   [FINALLY   — at try_addr + finally_offset (if has_finally)]
///   [<finally block>]
///   [ENDFINALLY]
fn void? CompilerContext.try_statement(&self) {
    self.expect(TokenType.TRY)!;

    // ── Eval-mode completion value tracking ──────────────────────────
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
    //      jumping away — so the restore only fires for normal completion).
    ushort try_completion_reg = 0;
    bool eval_try_tracking = false;

    // Emit TRY instruction (placeholder: A=0, BC=0, jump_slot BC=0)
    uint try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
    // Jump slot — the VM reads this word for the finally_offset (BC field)
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
            // Catch parameter — either a plain identifier (ES5) or a
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
                // — even empty `{}` patterns, per ES2019 §13.15.1.5.
                // Array patterns also throw if the value isn't iterable,
                // but iterator-protocol .next() already produces a TypeError
                // for null/undefined via GetMethod's ToObject step.
                if (ct == TokenType.LBRACE) {
                    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)catch_val_reg, 0, 0);
                    self.compile_catch_object_pattern(catch_val_reg)!;
                } else {
                    self.compile_catch_array_pattern(catch_val_reg)!;
                }
                self.expect(TokenType.RPAREN)!;
                self.free_reg(catch_val_reg);
            } else {
                Token catch_param = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(catch_param.str_value)) {
                    return self.fail("reserved word cannot be used as a catch parameter")~;
                }
                self.expect(TokenType.RPAREN)!;

                ushort catch_var = self.declare_var(catch_param.str_value, VAR);
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

        // Compile catch block
        self.block(false)!;

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
        // F to C. Return Completion(UpdateEmpty(F, undefined)).` — but for
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

/// Parse switch statement with correct fall-through (ES5 §12.11).
///
/// Each case body ends with a fall-through redirect JUMP patched after all
/// case clauses are parsed, so that when a matched case body completes (without
/// break) execution continues to the next case body rather than re-checking
/// the next case's comparison preamble. The `default` clause is handled with
/// a preamble JUMP when it is not the last clause, allowing subsequent cases
/// to be checked before falling through to default on no match.
fn void? CompilerContext.switch_statement(&self) {
    self.expect(TokenType.SWITCH)!;
    self.expect(TokenType.LPAREN)!;

    ushort disc_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.expect(TokenType.LBRACE)!;

    // Push a "loop" for break handling (break in switch exits the switch)
    // is_loop=false so continue skips this entry. This captures
    // cur_lex_depth BEFORE the CaseBlock's own lexical scope below, so a
    // `break` correctly POP_LEXes past the CaseBlock scope on its way out.
    self.push_loop(self.code_count, false);

    // ES2015 §14.12 / §13.12.9: CaseBlockEvaluation runs against a fresh
    // lexical environment (blockEnv) produced by BlockDeclarationInstantiation
    // over the CaseBlock — let/const/class/hoisted-function declarations made
    // directly in any case/default clause are scoped to the switch and must
    // not leak into the enclosing scope. This mirrors block()'s handling of
    // `{ ... }` blocks exactly, just with a wider pre-scan (block() only
    // needs let/const because class/function declarations there are already
    // handled by their own scoping — switch's CaseBlock is the one place
    // those additionally need confining).
    uint saved_switch_scope_depth = self.scope_depth;
    self.push_scope_marker();

    NameSpan[MAX_PRESCAN_NAMES] switch_lex_spans;
    uint num_switch_lex = self.pre_scan_switch_lexical_decls(&switch_lex_spans, MAX_PRESCAN_NAMES);

    bool switch_has_lex = num_switch_lex > 0;
    if (switch_has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
        self.cur_lex_depth++;
    }

    // TDZ-initialize every lexical declaration found by the pre-scan, exactly
    // like block()'s INITTZ pass, so accessing any of these names before their
    // declaration (or from outside the switch after it ends) throws a
    // ReferenceError instead of resolving to an outer binding.
    for (uint i = 0; i < num_switch_lex; i++) {
        char[] name = self.name_span_text(switch_lex_spans[i]);
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);

        // Mark any outer scope_stack entry with the same name as captured so
        // the compiler emits GETVAR instead of LDREG for it — without this, a
        // register-cached outer value would bypass the TDZ sentinel we just
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

    // Track all body entries (cases and default) in source order
    uint[64] body_addrs;
    uint[64] ft_jump_addrs;
    uint body_count = 0;
    bool has_default = false;
    uint default_body_idx = 0;
    bool default_not_last = false;

    // While compiling case/default bodies, function/generator/async-function
    // declarations found by the pre-scan above must bind into the switch's
    // own lex_env (PUTLEX) rather than the enclosing var_env (DECLVAR) — see
    // force_lexical_fn_decl's doc comment.
    bool saved_force_lexical_fn_decl = self.force_lexical_fn_decl;
    if (switch_has_lex) {
        self.force_lexical_fn_decl = true;
    }

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        if (self.match(TokenType.CASE)) {
            // Compile case expression
            ushort case_reg = self.expression()!;
            self.expect(TokenType.COLON)!;

            // Compare discriminant with case value
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)disc_reg, (uint)case_reg);
            self.free_reg(case_reg);

            // Jump to the case body if they match
            uint match_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

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
    // the address every "falls off the end" control-flow path converges on —
    // the last body's fall-through jump AND the "no match, no default" path
    // both target end_addr, so end_addr must point AT this POP_LEX (not past
    // it) or those paths would skip it entirely and leak the binding.
    // `break` unwinds past this scope separately via push_loop's
    // saved_lex_depth (see push_loop above), then jumps to end_addr itself —
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

    self.free_reg(disc_reg);
}

/// Parse a labeled statement: `identifier : statement`.
/// Supports labeled break and continue (ES5 §12.12).
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

    // Look ahead to determine if the inner statement is a loop
    TokenType next = self.peek_type();

    if (next == TokenType.FOR || next == TokenType.WHILE || next == TokenType.DO) {
        // The label refers to a loop. The loop will be pushed at index
        // self.loop_depth (the current depth before the loop's push_loop).
        self.labels[label_idx].loop_index = self.loop_depth;
        self.labels[label_idx].is_loop = true;
        self.statement()!;
    } else {
        // Non-loop label — push a virtual loop entry so break can target it.
        self.push_loop(self.code_count, false);
        self.labels[label_idx].loop_index = self.loop_depth - 1;
        self.labels[label_idx].is_loop = false;
        self.statement()!;
        self.pop_loop(); // patches all breaks targeting this label
    }

    // Labels are visible only while their labelled item is being compiled.
    // Keeping completed labels in the function-wide table incorrectly rejects
    // later statements that reuse the same label name (ES5 for-loop tests do
    // this several times in one script).
    self.label_count = saved_label_count;
}

/// Parse break statement.
/// If an identifier follows `break`, it's a labeled break (ES5 §12.12).
/// A line terminator between `break` and the identifier means unlabeled break.
fn void? CompilerContext.break_statement(&self) {
    self.expect(TokenType.BREAK)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled break — find the label and add jump to its loop's break chain
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                uint loop_idx = self.labels[i].loop_index;
                // Unwind the lex_env stack back to the labeled loop's depth.
                // Same pattern as the unlabeled break below — the labeled
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
                uint jump_addr = self.emit_jump(Opcode.BREAK);
                self.loop_stack[loop_idx].break_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].break_patch_head, jump_addr);
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled break — break out of the innermost loop or switch.
    // ES6 §13.13.1 BreakStatement : break ; — must be enclosed by an
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
        self.emit_abc(Opcode.ITER_CLOSE, (uint)self.loop_stack[loop_idx].iter_close_reg, 0, 0);
    }
    uint jump_addr = self.emit_jump(Opcode.BREAK);
    self.add_break_patch(jump_addr);

    self.match(TokenType.SEMICOLON);
}

/// Parse continue statement.
/// If an identifier follows `continue`, it's a labeled continue (ES5 §12.12).
/// A line terminator between `continue` and the identifier means unlabeled continue.
fn void? CompilerContext.continue_statement(&self) {
    self.expect(TokenType.CONTINUE)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled continue — find the label and jump to its loop's continue target
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                if (!self.labels[i].is_loop) {
                    // continue on a non-loop label is a syntax error
                    return COMPILE_ERROR~;
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
                        self.emit_abc(Opcode.ITER_CLOSE, (uint)self.loop_stack[li].iter_close_reg, 0, 0);
                    }
                }
                // Use deferred patching so the continue target can be updated
                // after the body is compiled (needed for rotated for-loops where
                // continue_target is set to incr_label after body compilation).
                uint jump_addr = self.emit_jump(Opcode.CONTINUE);
                self.loop_stack[loop_idx].continue_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled continue — jump to continue target of the innermost *real* loop
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
        uint jump_addr = self.emit_jump(Opcode.CONTINUE);
        self.loop_stack[loop_idx].continue_patch_head =
            self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
    } else {
        return COMPILE_ERROR~;
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse expression statement.
fn void? CompilerContext.expression_statement(&self) {
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
    self.match(TokenType.SEMICOLON);
}

/// Parse a function declaration (hoisted).
/// This is called during normal statement parsing for function declarations
/// that were NOT hoisted during the pre-scan phase.
fn void? CompilerContext.function_declaration(&self, bool is_async_decl = false) {
    self.expect(TokenType.FUNCTION)!;
    // Capture the byte offset of the `function` keyword before any subsequent
    // consume (identifier / star) clobbers lexer.token_start. Used downstream
    // by Function.prototype.toString for ES2019 §19.2.3.5 source retention.
    uint fn_kw_start = self.lexer.token_start;

    // Check if this function declaration was already hoisted during pre-scan
    // If so, skip it entirely to avoid duplicate compilation.
    // For global scope, check against hoisted_fn_names
    if (self.is_global) {
        // Extract function name from current lexer position
        Token? star_opt = self.lexer.next_token();
        if (catch _err2 = star_opt) return;
        if (star_opt.type == TokenType.STAR) {
            // Generator function - put star back and continue
            self.lexer.pushback(star_opt);
        } else {
            // Not a star - put it back (it's the function name)
            self.lexer.pushback(star_opt);
        }
        Token? name_opt = self.lexer.next_token();
        if (catch _err = name_opt) return;
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
                    // Skip the rest of the function body
                    self.skip_function_body();
                    // The body's closing `}` is a statement/declaration
                    // boundary — a following `/` starts a regexp literal.
                    self.lexer.note_block_close();
                    return;
                }
            }
        }
        // Put back the name token for normal processing
        self.lexer.pushback(name_opt);
    }

    // Function declarations are hoisted to function scope — need env.
    self.has_local_bindings = true;

    // Save and reset generator state: nested function declarations
    // inside a generator do not inherit the generator flag.
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Save the enclosing function's async flag — it must survive this
    // declaration (finish() reads it when the enclosing body completes).
    // The declaration's own async-ness comes from the is_async_decl
    // parameter, never from the enclosing flag.
    bool saved_is_async = self.is_async;
    self.is_async = false;

    // Regular function declarations are constructable per ES2015 §14.1.2 — they
    // can be invoked with `new` if they aren't arrow functions or methods with
    // super. Save/restore the constructable flag around the inner compile so
    // nested functions inside it inherit it.
    bool saved_is_constructable = self.is_constructable;
    self.is_constructable = true;

    // Check for generator star: function* name() {}
    // Generator functions are never constructable (ES2015 §14.4) — `new` on
    // one must throw TypeError, so is_constructable must flip to false here.
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
        self.is_constructable = false;
    }

    // Async functions are not constructors (ES2017 §14.7.5 — no [[Construct]]).
    if (is_async_decl) {
        self.is_constructable = false;
    }

    Token name_tok = self.expect(TokenType.IDENTIFIER)!;
    ushort func_reg = self.declare_var(name_tok.str_value, VAR);

    // Compile the function into a nested CompiledFunction with the
    // declaration's own async flag, then restore the enclosing one.
    self.is_async = is_async_decl;
    CompiledFunction* inner = self.compile_inner_function(name_tok.str_value, false, fn_kw_start)!;
    self.is_async = saved_is_async;

    // Restore generator flag
    self.is_generator = saved_is_generator;
    // Restore constructable flag (arrow fns/methods strip it via their own save/restore)
    self.is_constructable = saved_is_constructable;

    // Add to inner functions table
    uint inner_idx = self.add_inner_func(inner);

    // Emit CLOSURE to create the function object
    self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);

    uint name_idx = self.add_string_constant(name_tok.str_value);
    if (self.force_lexical_fn_decl) {
        // Inside a switch CaseBlock: scope this declaration to the switch's
        // own lex_env (installed by switch_statement's PUSH_LEX) instead of
        // the function-scoped var_env, so it disappears when the switch's
        // POP_LEX runs — matching BlockDeclarationInstantiation (§14.12).
        self.emit_a_bc(Opcode.PUTLEX, (uint)func_reg, name_idx);
    } else {
        // Declare the binding in the immediate var_env so inner functions can find it via GETVAR
        self.emit_a_bc(Opcode.DECLVAR, (uint)func_reg, name_idx);
    }

    // At global scope, free the register — the function object lives in the
    // environment via GETVAR/PUTVAR, not in a register-cached scope slot.
    if (self.is_global) {
        self.free_reg(func_reg);
    }
}

// ============================================================================
// ESM Import/Export declarations
// ============================================================================

/// Get the CompModuleDef* from the opaque current_module pointer.
/// Returns null if not in module mode.
fn CompModuleDef* CompilerContext.get_module_def(&self) {
    return (CompModuleDef*)self.current_module;
}

/// Expect the contextual keyword `from` (not a reserved word — must be
/// checked as an identifier with value "from").
fn void? CompilerContext.expect_from(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (!str_eq(tok.str_value, "from")) {
        return COMPILE_ERROR~;
    }
}

/// Match the contextual keyword `from` — consumes and returns true if the
/// current token is the identifier "from".
fn bool CompilerContext.match_from(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    // Peek at the actual token to check the string value
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (str_eq(tok.str_value, "from")) {
        return true;
    }
    // Not 'from' — push back
    self.lexer.pushback(tok);
    return false;
}

/// Expect the contextual keyword `as`.
fn void? CompilerContext.expect_as(&self) {
    Token tok = self.expect(TokenType.IDENTIFIER)!;
    if (!str_eq(tok.str_value, "as")) {
        return COMPILE_ERROR~;
    }
}

/// Match the contextual keyword `as`.
fn bool CompilerContext.match_as(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) return false;
    Token tok = tok_opt;
    if (str_eq(tok.str_value, "as")) {
        return true;
    }
    self.lexer.pushback(tok);
    return false;
}

/// Parse an ESM import declaration (ES6 §15.2.2).
///
/// Forms:
///   import 'module'
///   import defaultName from 'module'
///   import { a, b as c } from 'module'
///   import * as ns from 'module'
///   import defaultName, { a } from 'module'
///   import defaultName, * as ns from 'module'
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
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // import defaultName ...
    bool has_default = false;
    char[] default_local = {};
    if (tt == TokenType.IDENTIFIER) {
        Token name_tok = self.advance()!;
        default_local = name_tok.str_value;
        has_default = true;

        if (self.peek_type() == TokenType.COMMA) {
            self.advance()!; // consume ','
        } else {
            // Must be: import defaultName from 'module'
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
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
        Token ns_tok = self.expect(TokenType.IDENTIFIER)!;
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        mod_register_import(mod, ns_tok.str_value, "*", req_idx, true, false);
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

            // The import name (before 'as') is an IdentifierName and may be a
            // reserved word (e.g. 'default' in: import { default as d } from '…').
            Token name_tok = self.lexer.next_token()!;
            char[] import_name_str = name_tok.str_value;
            if (import_name_str.len == 0) {
                import_name_str = lexer::keyword_to_string(name_tok.type);
            }
            if (import_name_str.len == 0) return COMPILE_ERROR~;
            if (self.match_as()) {
                Token alias_tok = self.expect(TokenType.IDENTIFIER)!;
                local_names[binding_count] = alias_tok.str_value;
                import_names[binding_count] = import_name_str;
            } else {
                local_names[binding_count] = import_name_str;
                import_names[binding_count] = import_name_str;
            }
            binding_count++;

            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;
        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);

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

/// Parse an ESM export declaration (ES6 §15.2.3).
///
/// Forms:
///   export function foo() {}
///   export class Foo {}
///   export const/let/var x = ...
///   export { a, b as c }
///   export { a } from './other'
///   export * from './other'
///   export * as ns from './other'
///   export default function() {}
///   export default <expr>
///   export default class {}
fn void? CompilerContext.export_declaration(&self) {
    if (!self.is_module) {
        io::eprintfn("export declarations are only allowed in modules");
        return COMPILE_ERROR~;
    }

    self.expect(TokenType.EXPORT)!;

    if (self.current_module == null) return COMPILE_ERROR~;
    CompModuleDef* mod = self.get_module_def();

    TokenType tt = self.peek_type();

    // export default ...
    if (tt == TokenType.DEFAULT) {
        self.advance()!; // consume 'default'
        TokenType next = self.peek_type();

        // export default function() {} or export default function name() {}
        if (next == TokenType.FUNCTION) {
            self.advance()!; // consume 'function'
            // Byte offset of the `function` keyword before subsequent consumes
            // clobber lexer.token_start. Used by Function.prototype.toString.
            uint export_fn_src_start = self.lexer.token_start;
            bool is_gen = self.match(TokenType.STAR);
            if (is_gen) self.is_generator = true;

            // Check for named function expression
            char[] fn_name;
            if (self.peek_type() == TokenType.IDENTIFIER) {
                Token name_tok = self.advance()!;
                fn_name = name_tok.str_value;
            } else {
                fn_name = "*default*";
            }

            bool saved_is_async = self.is_async;
            self.is_async = false;
            // Regular functions are constructable (ES2015 §14.1.2); generators
            // never are (§14.4) — mirrors function_declaration's handling.
            bool saved_is_constructable = self.is_constructable;
            self.is_constructable = !self.is_generator;
            // Use the byte offset captured just past `self.advance()!` above.
            CompiledFunction* inner = self.compile_inner_function(fn_name, false, export_fn_src_start)!;
            self.is_constructable = saved_is_constructable;
            self.is_async = saved_is_async;
            self.is_generator = false;

            uint inner_idx = self.add_inner_func(inner);

            ushort func_reg = self.declare_var("*default*", VAR);
            // `export default function` is a hoisted function declaration bound
            // to *default* at link time (ECMA-262 16.2.1.5.5 step 17). Record
            // it for the linker and suppress body CLOSURE+DECLVAR so a cyclic
            // early import of the default export sees the hoisted function.
            mod_register_func_decl(mod, "*default*", inner_idx);
            self.free_reg(func_reg);

            mod_register_export(mod, "*default*", "default", false, 0);
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default class {} or export default class Foo {}
        if (next == TokenType.CLASS) {
            // Parse class and assign to *default*
            self.class_declaration()!;
            mod_register_export(mod, "*default*", "default", false, 0);
            self.match(TokenType.SEMICOLON);
            return;
        }

        // export default <expr>
        ushort val_reg = self.assignment_expr()!;
        uint def_name_idx = self.add_string_constant("*default*");
        self.emit_a_bc(Opcode.DECLVAR, (uint)val_reg, def_name_idx);
        self.free_reg(val_reg);
        mod_register_export(mod, "*default*", "default", false, 0);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export * from './other'
    if (tt == TokenType.STAR) {
        self.advance()!; // consume '*'

        // export * as ns from './other'
        if (self.match_as()) {
            Token ns_tok = self.expect(TokenType.IDENTIFIER)!;
            self.expect_from()!;
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
            mod_register_export(mod, "*", ns_tok.str_value, true, req_idx);
            self.match(TokenType.SEMICOLON);
            return;
        }

        self.expect_from()!;
        Token spec_tok = self.expect(TokenType.STRING)!;
        uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
        mod_register_star_export(mod, req_idx);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export { a, b as c } or export { a } from './other'
    if (tt == TokenType.LBRACE) {
        self.advance()!; // consume '{'

        char[][32] local_names;
        char[][32] export_names;
        uint count = 0;

        while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
            if (count >= 32) return COMPILE_ERROR~;
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.match_as()) {
                // The exported name (after 'as') is a ModuleExportName / IdentifierName:
                // reserved words like 'default' are valid here.
                Token alias_tok = self.lexer.next_token()!;
                char[] alias_str = alias_tok.str_value;
                if (alias_str.len == 0) {
                    alias_str = lexer::keyword_to_string(alias_tok.type);
                }
                if (alias_str.len == 0) return COMPILE_ERROR~;
                local_names[count] = name_tok.str_value;
                export_names[count] = alias_str;
            } else {
                local_names[count] = name_tok.str_value;
                export_names[count] = name_tok.str_value;
            }
            count++;
            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACE)!;

        // Check for 'from' clause (indirect export)
        if (self.match_from()) {
            Token spec_tok = self.expect(TokenType.STRING)!;
            uint req_idx = mod_register_req_module(mod, spec_tok.str_value);
            for (uint i = 0; i < count; i++) {
                mod_register_export(mod, local_names[i], export_names[i], true, req_idx);
            }
        } else {
            // Local export: the names are local bindings. Look up each
            // name's declared kind so a re-export of an already-declared
            // `let`/`const`/`class` binding is TDZ-eligible too (e.g.
            // `let a = 1; export { a };`).
            for (uint i = 0; i < count; i++) {
                bool lex = self.is_name_lexical(local_names[i]);
                // A re-export of a top-level `function` declaration needs no
                // special handling here: the function is already recorded in
                // func_decls (by hoist_global_fn_decls) and bound at link time,
                // and this export simply aliases that local binding.
                mod_register_export(mod, local_names[i], export_names[i], false, 0, lex);
            }
        }

        self.match(TokenType.SEMICOLON);
        return;
    }

    // export function foo() {}
    if (tt == TokenType.FUNCTION) {
        self.advance()!; // consume 'function'
        // Byte offset of the `function` keyword — captured before subsequent
        // consumes clobber lexer.token_start. Used by toString.
        uint named_export_src_start = self.lexer.token_start;
        bool is_gen = self.match(TokenType.STAR);
        if (is_gen) self.is_generator = true;

        bool saved_is_async = self.is_async;
        self.is_async = false;

        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        ushort func_reg = self.declare_var(name_tok.str_value, VAR);

        // Regular functions are constructable (ES2015 §14.1.2); generators
        // never are (§14.4) — mirrors function_declaration's handling.
        bool saved_is_constructable = self.is_constructable;
        self.is_constructable = !self.is_generator;
        CompiledFunction* inner = self.compile_inner_function(name_tok.str_value, false, named_export_src_start)!;
        self.is_constructable = saved_is_constructable;
        self.is_async = saved_is_async;
        self.is_generator = false;

        uint inner_idx = self.add_inner_func(inner);

        // A top-level `export function` declaration is instantiated at link
        // time (ECMA-262 16.2.1.5.5 step 17), not by the body — record it for
        // the linker and suppress body CLOSURE+DECLVAR so a cyclic early
        // import sees the hoisted function and its identity stays stable.
        mod_register_func_decl(mod, name_tok.str_value, inner_idx);
        self.free_reg(func_reg);

        mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0);
        self.match(TokenType.SEMICOLON);
        return;
    }

    // export class Foo {}
    if (tt == TokenType.CLASS) {
        // class_declaration() expects CLASS already consumed, but we need the name first.
        // Read the name, then put tokens back and call class_declaration().
        // Peek ahead for the class name
        Token saved_class = self.advance()!; // consume CLASS
        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        // Put both back so class_declaration can re-consume them
        self.lexer.pushback(name_tok);
        self.lexer.pushback(saved_class);
        self.class_declaration()!;
        mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0, true);
        self.match(TokenType.SEMICOLON);
        return;
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

        for (;;) {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) {
                return self.fail("reserved word cannot be used as a binding identifier")~;
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

            mod_register_export(mod, name_tok.str_value, name_tok.str_value, false, 0, is_lexical);

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

/// Array catch pattern. The '[' has already been consumed.
/// Uses the iterator protocol on catch_val_reg to extract elements.
/// Array catch pattern (`catch ([a, b]) {}`). The '[' has already been consumed.
/// Collects via the shared collector, declares each leaf LET-scoped in the catch
/// scope, and extracts through emit_destruct_bindings (iterator protocol,
/// defaults, rest, IteratorClose) — the single destructuring algorithm.
fn void? CompilerContext.compile_catch_array_pattern(&self, ushort catch_val_reg) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_arr_param_binds(binds[..], &count, catch_val_reg, 0xFFFF)!;
    self.emit_catch_pattern(binds[..], count, catch_val_reg);
}

/// Shared tail for both catch patterns: declare LET leaves, then emit.
fn void CompilerContext.emit_catch_pattern(&self, DestructBind[] binds, uint count, ushort src_reg) {
    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
        binding_regs[i] = self.declare_var(hs.get_data(), ScopeKind.LET);
    }
    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = src_reg;
    }
    self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                DestructStoreMode.DECLARE, true, false);
}

/// Object catch pattern (`catch ({e}) {}`). The '{' has already been consumed.
/// The caller emits RequireObjectCoercible on catch_val_reg. Collects via the
/// shared collector and extracts through emit_destruct_bindings.
fn void? CompilerContext.compile_catch_object_pattern(&self, ushort catch_val_reg) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_obj_param_binds(binds[..], &count, catch_val_reg, 0xFFFF)!;
    self.emit_catch_pattern(binds[..], count, catch_val_reg);
}
