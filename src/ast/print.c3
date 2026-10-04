// Debug dump of the flat AST: one node per line, children indented.
module boomkat::ast;

import boomkat::lexer;
import std::io;

// How a node's lhs / rhs slot is read when dumping.
enum Slot : char {
    NONE,    // unused
    NODE,    // node id, 0 prints `_`
    ATOM,    // atom id
    LIST,    // extra index of a node list
    CASES,   // extra index of (list of CASE, offset of the case block `{`)
    PAIR,    // extra index of two node ids
    TRIPLE,  // extra index of three node ids
    QUAD,    // extra index of four node ids
    FUNC,    // extra index of a function record
    CLASS,   // extra index of a class record
    TEMPLATE, // extra index of an interleaved template list
    NUM_LO,  // low half of a number's bits
    NUM_HI,  // high half of a number's bits
}

fn Slot[2] slots_of(NodeTag t) {
    switch (t) {
        case NUMBER: return { Slot.NUM_LO, Slot.NUM_HI };
        case BIGINT:
        case STRING:
        case REGEX:
        case IDENT:
        case PRIVATE_NAME: return { Slot.ATOM, Slot.NONE };
        case TEMPLATE: return { Slot.TEMPLATE, Slot.NONE };
        case ARRAY:
        case OBJECT:
        case SEQUENCE:
        case ARRAY_PAT:
        case OBJECT_PAT:
        case STATIC_BLOCK:
        case BLOCK:
        case PROGRAM: return { Slot.LIST, Slot.NONE };
        case FUNC_EXPR:
        case ARROW:
        case FUNC_DECL: return { Slot.NODE, Slot.FUNC };
        case CLASS_EXPR:
        case CLASS_DECL: return { Slot.NODE, Slot.CLASS };
        case COND:
        case IF:
        case FOR_IN:
        case FOR_OF: return { Slot.NODE, Slot.PAIR };
        case TRY: return { Slot.NODE, Slot.TRIPLE };
        case FOR: return { Slot.QUAD, Slot.NONE };
        case MEMBER:
        case PRIVATE_MEMBER: return { Slot.NODE, Slot.ATOM };
        case PRIVATE_IN: return { Slot.ATOM, Slot.NODE };
        case SUPER_MEMBER: return { Slot.NONE, Slot.ATOM };
        case SUPER_INDEX: return { Slot.NONE, Slot.NODE };
        case SUPER_CALL: return { Slot.NONE, Slot.LIST };
        case CALL:
        case NEW: return { Slot.NODE, Slot.LIST };
        case VAR_DECL: return { Slot.LIST, Slot.NONE };
        case SWITCH: return { Slot.NODE, Slot.CASES };
        case CASE: return { Slot.NODE, Slot.LIST };
        case BREAK:
        case CONTINUE: return { Slot.ATOM, Slot.NONE };
        case LABELED: return { Slot.ATOM, Slot.NODE };
        case IMPORT_DECL: return { Slot.ATOM, Slot.LIST };
        case IMPORT_SPEC: return { Slot.ATOM, Slot.NODE };
        case EXPORT_NAMED: return { Slot.LIST, Slot.ATOM };
        case EXPORT_SPEC: return { Slot.ATOM, Slot.ATOM };
        case EXPORT_ALL: return { Slot.ATOM, Slot.ATOM };
        default: return { Slot.NODE, Slot.NODE };
    }
}

struct AstPrinter {
    Ast* ast;
}

fn void indent(uint depth) {
    for (uint i = 0; i < depth; i++) io::print("  ");
}

fn void AstPrinter.atom(&self, uint a) {
    if (a == INVALID_ATOM) {
        io::print("<invalid>");
        return;
    }
    if (a == ATOM_NONE) {
        io::print("_");
        return;
    }
    char[] s = self.ast.atoms.get(a);
    io::print("\"");
    foreach (c : s) {
        if (c == '\n') {
            io::print("\\n");
        } else if (c == '"' || c == '\\') {
            io::printf("\\%c", c);
        } else if (c < 0x20) {
            io::printf("\\x%02x", c);
        } else {
            io::printf("%c", c);
        }
    }
    io::print("\"");
}

fn void AstPrinter.list(&self, uint list, uint depth) {
    uint n = self.ast.list_len(list);
    for (uint i = 0; i < n; i++) {
        self.node(self.ast.list_item(list, i), depth);
    }
}

fn void AstPrinter.child(&self, String label, uint n, uint depth) {
    indent(depth);
    io::printf("%s:\n", label);
    self.node(n, depth + 1);
}

fn void AstPrinter.slot(&self, Slot k, uint v, uint depth, uint tag_flags_unused) {
    switch (k) {
        case NONE: return;
        case NODE:
            if (v != 0) self.node(v, depth);
        case ATOM:
            indent(depth);
            self.atom(v);
            io::print("\n");
        case LIST: self.list(v, depth);
        case CASES: self.list(self.ast.extra[v], depth);
        case PAIR:
            self.node(self.ast.extra[v], depth);
            self.node(self.ast.extra[v + 1], depth);
        case TRIPLE:
            self.node(self.ast.extra[v], depth);
            self.node(self.ast.extra[v + 1], depth);
            self.node(self.ast.extra[v + 2], depth);
        case QUAD:
            self.node(self.ast.extra[v], depth);
            self.node(self.ast.extra[v + 1], depth);
            self.node(self.ast.extra[v + 2], depth);
            self.node(self.ast.extra[v + 3], depth);
        case FUNC:
            self.function(v, depth);
        case CLASS:
            indent(depth);
            io::printf("class src=%d..%d\n", self.ast.field(v, CLS_SRC_START), self.ast.field(v, CLS_SRC_END));
            self.child("heritage", self.ast.field(v, CLS_HERITAGE), depth + 1);
            indent(depth + 1);
            io::print("members:\n");
            self.list(self.ast.field(v, CLS_MEMBERS), depth + 2);
        case TEMPLATE:
            uint len = self.ast.extra[v];
            uint parts = (len - 2) / 3 + 1;
            for (uint i = 0; i < parts; i++) {
                indent(depth);
                io::print("text ");
                self.atom(self.ast.template_cooked(v, i));
                io::print(" raw ");
                self.atom(self.ast.template_raw(v, i));
                io::print("\n");
                if (i + 1 < parts) self.node(self.ast.template_expr(v, i), depth);
            }
        case NUM_LO:
        case NUM_HI: return;
    }
}

fn void AstPrinter.function(&self, uint rec, uint depth) {
    uint f = self.ast.field(rec, FN_FLAGS);
    indent(depth);
    io::printf("fn flags=0x%x src=%d..%d\n", f, self.ast.field(rec, FN_SRC_START), self.ast.field(rec, FN_SRC_END));
    indent(depth + 1);
    io::print("params:\n");
    self.list(self.ast.field(rec, FN_PARAMS), depth + 2);
    indent(depth + 1);
    io::print("body:\n");
    self.node(self.ast.field(rec, FN_BODY), depth + 2);
}

fn String op_text(char flags) {
    return (String)lexer::token_type_name((TokenType)flags);
}

fn void AstPrinter.node(&self, uint n, uint depth) {
    indent(depth);
    if (n == 0) {
        io::print("_\n");
        return;
    }
    NodeTag t = self.ast.tags[n];
    char f = self.ast.flags[n];
    io::printf("%s", NodeTag::names[t.ordinal]);
    switch (t) {
        case UNARY:
        case UPDATE_PRE:
        case UPDATE_POST:
        case BINARY:
        case LOGICAL:
        case ASSIGN:
            io::printf(" %s", op_text(f & 0x7F));
        case NUMBER:
            ulong bits = (ulong)self.ast.lhs[n] | ((ulong)self.ast.rhs[n] << 32);
            io::printf(" %g", bitcast(bits, double));
        default:
            if ((f & 0x7F) != 0) io::printf(" flags=0x%x", f & 0x7F);
    }
    if ((f & FLAG_PAREN) != 0) io::print(" (paren)");
    io::printf(" @%d", self.ast.main_tok[n]);
    io::print("\n");
    Slot[2] sl = slots_of(t);
    switch (t) {
        case IF:
            self.node(self.ast.lhs[n], depth + 1);
            self.node(self.ast.extra[self.ast.rhs[n]], depth + 1);
            self.node(self.ast.extra[self.ast.rhs[n] + 1], depth + 1);
        default:
            self.slot(sl[0], self.ast.lhs[n], depth + 1, 0);
            self.slot(sl[1], self.ast.rhs[n], depth + 1, 0);
    }
}

fn void dump_ast(Ast* ast, uint root) {
    AstPrinter p = { .ast = ast };
    p.node(root, 0);
}

// Scope tree with each scope's bindings; `*` marks a captured binding.
fn void dump_scopes(Resolver* r) {
    for (uint s = 1; s < (uint)r.scopes.len; s++) {
        Scope* sc = &r.scopes.data[s];
        io::printf("scope %d %s parent=%d func=%d @%d flags=0x%x\n", s, sc.kind, sc.parent, sc.func, sc.open, sc.flags);
        for (uint b = 1; b < (uint)r.bindings.len; b++) {
            Binding* bd = &r.bindings.data[b];
            if (bd.scope != s) continue;
            char[] name = r.ast.atoms.get(bd.name);
            io::printf("  %s %s%s\n", bd.kind, (String)name, bd.captured ? " *" : "");
        }
    }
}
