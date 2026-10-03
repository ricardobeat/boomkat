// Flat AST (plan 101).
//
// A tree is a set of parallel columns indexed by a `uint` node id. Id 0 is the
// null node, so every column carries a dummy entry at index 0. Children are
// appended before their parent, so a parent's id is greater than every
// descendant's, and a subtree is one contiguous id range ending at its root.
//
// A node is (tag, flags, main_tok, lhs, rhs). `main_tok` is the byte offset of
// the node's main token. What `lhs` and `rhs` hold depends on the tag and is
// documented on each tag below: a child id, an atom id, an index into `extra`,
// or inline payload bits. A variable-length list is stored in `extra` as
// `[count, item0, item1, ...]` and referred to by the index of `count`.
//
// Unless a tag says otherwise, a "list" field is an `extra` index and an "atom"
// field is an index into the atom table.
module boomkat::ast;

import boomkat::ast::vec;

enum NodeTag : char {
    NONE,

    // ---- Literals and primary expressions ----
    NUMBER,          // lhs, rhs = low and high 32 bits of the f64
    BIGINT,          // lhs = atom: digit text without the `n` suffix
    STRING,          // lhs = atom: decoded value. flags: STR_*
    REGEX,           // lhs = atom: the whole literal text `/body/flags`
    TEMPLATE,        // lhs = list: see Ast.template_*; a no-substitution template has one text part
    TAGGED_TEMPLATE, // lhs = tag expression, rhs = TEMPLATE
    IDENT,           // lhs = atom. flags: IDENT_ESCAPED
    THIS,
    NULL_LIT,
    TRUE_LIT,
    FALSE_LIT,
    NEW_TARGET,
    IMPORT_META,
    ARRAY,           // lhs = list of elements; a hole is node 0
    OBJECT,          // lhs = list of property nodes (PROP_*)
    FUNC_EXPR,       // lhs = name IDENT or 0, rhs = extra index of a function record (FN_*)
    ARROW,           // as FUNC_EXPR; the record's body is an expression when FN_EXPR_BODY is set
    CLASS_EXPR,      // lhs = name IDENT or 0, rhs = extra index of a class record (CLS_*)

    // ---- Operators ----
    UNARY,           // lhs = operand, flags = TokenType: + - ! ~ typeof void delete
    UPDATE_PRE,      // lhs = operand, flags = TokenType INC or DEC
    UPDATE_POST,     // as UPDATE_PRE
    BINARY,          // lhs, rhs, flags = TokenType of the operator (excluding && || ??)
    LOGICAL,         // lhs, rhs, flags = TokenType: AND OR NULLISH
    ASSIGN,          // lhs = target, rhs = value, flags = TokenType: ASSIGN, a compound or a logical assignment
    COND,            // lhs = test, rhs = extra index of [consequent, alternate]
    SEQUENCE,        // lhs = list of expressions
    SPREAD,          // lhs = operand (array element, call argument, object spread)
    AWAIT,           // lhs = operand
    YIELD,           // lhs = operand or 0
    YIELD_STAR,      // lhs = operand

    // ---- Member access and calls ----
    MEMBER,          // lhs = object, rhs = atom (property name). flags: OPTIONAL
    INDEX,           // lhs = object, rhs = key expression. flags: OPTIONAL
    PRIVATE_MEMBER,  // lhs = object, rhs = atom (name without `#`). flags: OPTIONAL
    PRIVATE_IN,      // lhs = atom (name without `#`), rhs = right operand of `#x in obj`
    SUPER_MEMBER,    // rhs = atom
    SUPER_INDEX,     // rhs = key expression
    SUPER_CALL,      // rhs = list of arguments
    CALL,            // lhs = callee, rhs = list of arguments. flags: OPTIONAL
    NEW,             // lhs = callee, rhs = list of arguments
    IMPORT_CALL,     // lhs = specifier, rhs = options expression or 0
    OPT_CHAIN,       // lhs = the chain expression: the short-circuit boundary of `a?.b.c`

    // ---- Object and class members ----
    PROP_INIT,       // `key: value` lhs = key, rhs = value. flags: PROP_COMPUTED
    PROP_SHORTHAND,  // `a` or the cover initializer `a = 1`. lhs = IDENT, rhs = default expression or 0
    PROP_GET,        // lhs = key, rhs = FUNC_EXPR. flags: PROP_COMPUTED
    PROP_SET,        // as PROP_GET
    PROP_METHOD,     // as PROP_GET
    PROP_SPREAD,     // `...expr` lhs = expression
    CLASS_METHOD,    // lhs = key, rhs = FUNC_EXPR. flags: PROP_COMPUTED, MEMBER_STATIC, MEMBER_GET, MEMBER_SET
    CLASS_FIELD,     // lhs = key, rhs = initializer or 0. flags: PROP_COMPUTED, MEMBER_STATIC
    STATIC_BLOCK,    // lhs = list of statements
    PRIVATE_NAME,    // a class member key `#x`. lhs = atom (without `#`)

    // ---- Binding and assignment patterns (an expression retags into these) ----
    ARRAY_PAT,       // lhs = list of elements; a hole is node 0
    OBJECT_PAT,      // lhs = list of PAT_PROP / REST
    PAT_PROP,        // lhs = key, rhs = value pattern. flags: PROP_COMPUTED. With PROP_SHORTHAND_PAT
                     // (`{a}`, `{a = 1}`) lhs is the IDENT that is both key and target and rhs is the default or 0
    ASSIGN_PAT,      // lhs = target pattern, rhs = default expression
    REST,            // lhs = target pattern

    // ---- Statements ----
    EXPR_STMT,       // lhs = expression
    DIRECTIVE,       // lhs = STRING node of a directive-prologue entry. flags: DIR_USE_STRICT
    VAR_DECL,        // lhs = list of DECLARATOR. flags: VAR_KIND_*
    DECLARATOR,      // lhs = binding pattern, rhs = initializer or 0
    BLOCK,           // lhs = list of statements
    EMPTY_STMT,
    IF,              // lhs = test, rhs = extra index of [consequent, alternate or 0]
    FOR,             // lhs = extra index of [init, test, update, body]; absent parts are 0
    FOR_IN,          // lhs = left (VAR_DECL or target), rhs = extra index of [right, body]
    FOR_OF,          // as FOR_IN. flags: FOR_AWAIT
    WHILE,           // lhs = test, rhs = body
    DO_WHILE,        // lhs = body, rhs = test
    RETURN,          // lhs = argument or 0
    BREAK,           // lhs = label atom or 0
    CONTINUE,        // as BREAK
    THROW,           // lhs = argument
    TRY,             // lhs = block, rhs = extra index of [param or 0, handler or 0, finalizer or 0]
    SWITCH,          // lhs = discriminant, rhs = list of CASE
    CASE,            // lhs = test or 0 for `default`, rhs = list of statements
    LABELED,         // lhs = label atom, rhs = body
    WITH,            // lhs = object, rhs = body
    DEBUGGER,
    FUNC_DECL,       // lhs = name IDENT, rhs = function record
    CLASS_DECL,      // lhs = name IDENT, rhs = class record

    // ---- Modules ----
    IMPORT_DECL,     // lhs = source atom, rhs = list of IMPORT_SPEC; 0 specifiers and no clause is a bare import
    IMPORT_SPEC,     // lhs = imported name atom (`default` for a default import, `*` with IMPORT_NAMESPACE), rhs = local IDENT
    EXPORT_NAMED,    // lhs = list of EXPORT_SPEC, rhs = source atom, or 0 when it does not re-export
    EXPORT_SPEC,     // lhs = local name atom, rhs = exported name atom
    EXPORT_ALL,      // lhs = source atom, rhs = exported namespace name atom, or 0 for `export *`
    EXPORT_DECL,     // lhs = the declaration (VAR_DECL, FUNC_DECL, CLASS_DECL)
    EXPORT_DEFAULT,  // lhs = FUNC_DECL / CLASS_DECL (named or anonymous) or an expression. flags: EXPORT_DEFAULT_EXPR

    // ---- Roots ----
    PROGRAM,         // lhs = list of statements. flags: PROGRAM_MODULE, PROGRAM_STRICT
}

// ---- flag bits ----

// Valid on any expression node.
const char FLAG_PAREN = 0x80;       // the expression was written in parentheses: `(a)` is IDENT with this bit

const char FLAG_OPTIONAL = 0x01;    // MEMBER / INDEX / PRIVATE_MEMBER / CALL written with `?.`
const char IDENT_ESCAPED = 0x01;
const char STR_OCTAL = 0x01;        // the literal holds a legacy octal or \8 \9 escape
const char STR_DIRECTIVE_RAW = 0x02;
const char PROP_COMPUTED = 0x01;
const char PROP_SHORTHAND_PAT = 0x02;
const char MEMBER_STATIC = 0x02;
const char MEMBER_GET = 0x04;
const char MEMBER_SET = 0x08;
const char FOR_AWAIT = 0x01;
const char DIR_USE_STRICT = 0x01;
const char VAR_KIND_VAR = 0;
const char VAR_KIND_LET = 1;
const char VAR_KIND_CONST = 2;
const char EXPORT_DEFAULT_EXPR = 0x01;
const char IMPORT_NAMESPACE = 0x01;
const char PROGRAM_MODULE = 0x01;
const char PROGRAM_STRICT = 0x02;

// Function record, an `extra` slice starting at the index in a function node's `rhs`.
const uint FN_FLAGS = 0;      // FNF_* bits
const uint FN_PARAMS = 1;     // list of parameter patterns (REST last)
const uint FN_BODY = 2;       // BLOCK node, or the expression of an expression-bodied arrow
const uint FN_SRC_START = 3;  // byte offset where Function.prototype.toString starts
const uint FN_SRC_END = 4;    // byte offset one past the function's last byte
const uint FN_SIZE = 5;

const uint FNF_ASYNC = 1 << 0;
const uint FNF_GENERATOR = 1 << 1;
const uint FNF_EXPR_BODY = 1 << 2;      // arrow with an expression body
const uint FNF_STRICT = 1 << 3;         // the function's own code is strict (directive or inherited)
const uint FNF_USE_STRICT = 1 << 4;     // the function's own prologue holds "use strict"
const uint FNF_METHOD = 1 << 5;         // object or class method, getter, setter
const uint FNF_GETTER = 1 << 6;
const uint FNF_SETTER = 1 << 7;
const uint FNF_CTOR = 1 << 8;           // a class constructor
const uint FNF_DERIVED_CTOR = 1 << 9;   // a constructor of a class with a heritage
const uint FNF_SIMPLE_PARAMS = 1 << 10; // only plain identifiers: no defaults, rest or patterns
const uint FNF_STATIC_BLOCK = 1 << 11;  // a class static block body
const uint FNF_FIELD_INIT = 1 << 12;    // a synthesised class field initialiser body

// Class record.
const uint CLS_HERITAGE = 0;  // expression or 0
const uint CLS_MEMBERS = 1;   // list of CLASS_METHOD / CLASS_FIELD / STATIC_BLOCK
const uint CLS_SRC_START = 2;
const uint CLS_SRC_END = 3;
const uint CLS_SIZE = 4;

// A source position, from a byte offset.
struct SourcePos {
    uint line;
    uint col;
}

struct Ast {
    char[] source;
    // Columns. Index 0 is the null node.
    Vec{NodeTag} tags;
    Vec{char} flags;
    Vec{uint} main_tok;
    Vec{uint} lhs;
    Vec{uint} rhs;
    // Variable-length lists and records. Index 0 is reserved so 0 means "none".
    Vec{uint} extra;
    // Byte offset of the start of each line, ascending, filled by the parser as it
    // lexes. line_starts[0] is 0.
    Vec{uint} line_starts;
    AtomTable atoms;
}

fn void Ast.init(&self, char[] source) {
    self.source = source;
    self.tags.init();
    self.flags.init();
    self.main_tok.init();
    self.lhs.init();
    self.rhs.init();
    self.extra.init();
    self.line_starts.init();
    self.atoms.init();
    // Reserve the null node and the null extra index.
    self.tags.push(NodeTag.NONE);
    self.flags.push(0);
    self.main_tok.push(0);
    self.lhs.push(0);
    self.rhs.push(0);
    self.extra.push(0);
    self.line_starts.push(0);
}

fn void Ast.free(&self) {
    self.tags.free();
    self.flags.free();
    self.main_tok.free();
    self.lhs.free();
    self.rhs.free();
    self.extra.free();
    self.line_starts.free();
    self.atoms.free();
}

fn uint Ast.node_count(&self) @inline {
    return (uint)self.tags.len;
}

// Append a node and return its id.
fn uint Ast.add(&self, NodeTag tag, char flags, uint tok, uint lhs, uint rhs) {
    uint id = (uint)self.tags.len;
    self.tags.push(tag);
    self.flags.push(flags);
    self.main_tok.push(tok);
    self.lhs.push(lhs);
    self.rhs.push(rhs);
    return id;
}

macro NodeTag Ast.tag(&self, uint n) => self.tags[n];
macro char Ast.flag(&self, uint n) => self.flags[n];
macro uint Ast.tok(&self, uint n) => self.main_tok[n];
macro uint Ast.left(&self, uint n) => self.lhs[n];
macro uint Ast.right(&self, uint n) => self.rhs[n];

fn void Ast.set_tag(&self, uint n, NodeTag tag) @inline { self.tags[n] = tag; }
fn void Ast.set_flags(&self, uint n, char f) @inline { self.flags[n] = f; }
fn void Ast.set_lhs(&self, uint n, uint v) @inline { self.lhs[n] = v; }
fn void Ast.set_rhs(&self, uint n, uint v) @inline { self.rhs[n] = v; }

// Append `[count, items...]` to `extra` and return the index of `count`. An empty
// list is stored too, so a list field is never ambiguous with "absent".
fn uint Ast.add_list(&self, uint[] items) {
    uint at = (uint)self.extra.len;
    self.extra.push((uint)items.len);
    foreach (it : items) self.extra.push(it);
    return at;
}

fn uint Ast.list_len(&self, uint list) @inline {
    return self.extra[list];
}

fn uint Ast.list_item(&self, uint list, uint i) @inline {
    return self.extra[list + 1 + i];
}

// Reserve `n` zeroed `extra` slots (a record) and return the index of the first.
fn uint Ast.add_record(&self, uint n) {
    uint at = (uint)self.extra.len;
    for (uint i = 0; i < n; i++) self.extra.push(0);
    return at;
}

fn uint Ast.field(&self, uint rec, uint field) @inline {
    return self.extra[rec + field];
}

fn void Ast.set_field(&self, uint rec, uint field, uint v) @inline {
    self.extra[rec + field] = v;
}

// A template literal's `lhs` list holds `cooked0, raw0, expr0, cooked1, raw1, expr1, ..., cookedN, rawN`
// for N substitutions: N+1 text parts with an expression after each but the last. A cooked atom of
// INVALID_ATOM marks an invalid escape, which a tagged template allows.
const uint INVALID_ATOM = 0xFFFFFFFF;

fn uint Ast.template_exprs(&self, uint list) @inline { return (self.extra.data[list] - 2) / 3; }
fn uint Ast.template_cooked(&self, uint list, uint i) @inline { return self.extra.data[list + 1 + 3 * i]; }
fn uint Ast.template_raw(&self, uint list, uint i) @inline { return self.extra.data[list + 2 + 3 * i]; }
fn uint Ast.template_expr(&self, uint list, uint i) @inline { return self.extra.data[list + 3 + 3 * i]; }

// A mark restores the columns to a prior length, discarding everything appended since.
struct AstMark {
    uint nodes;
    uint extra;
}

fn AstMark Ast.mark(&self) {
    return { (uint)self.tags.len, (uint)self.extra.len };
}

fn void Ast.truncate(&self, AstMark m) {
    self.tags.truncate(m.nodes);
    self.flags.truncate(m.nodes);
    self.main_tok.truncate(m.nodes);
    self.lhs.truncate(m.nodes);
    self.rhs.truncate(m.nodes);
    self.extra.truncate(m.extra);
}

// 1-based line and column of a byte offset. The line table covers the lines the lexer has passed,
// which is every offset a node can name.
fn SourcePos Ast.position(&self, uint offset) {
    sz lo = 0;
    sz hi = self.line_starts.len;
    while (hi - lo > 1) {
        sz mid = (lo + hi) / 2;
        if (self.line_starts.data[mid] <= offset) { lo = mid; } else { hi = mid; }
    }
    return { (uint)lo + 1, offset - self.line_starts.data[lo] + 1 };
}
