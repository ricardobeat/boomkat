module boomkat::compiler;

import boomkat::ast;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::builtins;
import boomkat::vm;
import boomkat::dtoa_bindings;

// One temporary column per compilation unit, shared by all its function
// contexts. The internal DELETED sentinel means unknown, leaving undefined
// available for a proven-safe `void` expression. Only primitive, effect-free
// syntax receives a fact: knowing a runtime value
// alone would not justify omitting generation's remaining early-error checks.
struct ConstantFacts {
    ast::Ast* tree;
    TVal* values;
    ValueKind* kinds;
    ConstantFacts* prev;
    Heap* heap;
    ValueRoot* string_roots;
    uint string_count;
    uint string_bytes;
}

// Successful evaluation facts, independent of effects: these authorize only
// removing an identity coercion after the original expression is evaluated.
enum ValueKind : char { UNKNOWN, NUMBER, INT32, UINT32, BOOLEAN }

fn ValueKind expression_kind(ast::Ast* tree, uint n, ValueKind* kinds) {
    NodeTag tag = tree.tags.data[n];
    if (tag == NodeTag.NUMBER) return ValueKind.NUMBER;
    if (tag == NodeTag.TRUE_LIT || tag == NodeTag.FALSE_LIT) return ValueKind.BOOLEAN;
    if (tag != NodeTag.BINARY && tag != NodeTag.UNARY) return ValueKind.UNKNOWN;
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    ValueKind left = kinds[tree.lhs.data[n]];
    if (tag == NodeTag.UNARY) {
        if (op == TokenType.PLUS) return ValueKind.NUMBER;
        if (op == TokenType.LOG_NOT) return ValueKind.BOOLEAN;
        if (op == TokenType.BIT_NOT && (left == ValueKind.NUMBER || left == ValueKind.INT32 || left == ValueKind.UINT32)) return ValueKind.INT32;
        return ValueKind.UNKNOWN;
    }
    ValueKind right = kinds[tree.rhs.data[n]];
    bool ln = left == ValueKind.NUMBER || left == ValueKind.INT32 || left == ValueKind.UINT32;
    bool rn = right == ValueKind.NUMBER || right == ValueKind.INT32 || right == ValueKind.UINT32;
    switch (op) {
        case USHR: return ValueKind.UINT32;
        case BIT_AND: case BIT_OR: case BIT_XOR: case SHL: case SHR:
            // One Number operand excludes successful BigInt evaluation.
            if (ln || rn) return ValueKind.INT32;
        case PLUS: case MINUS: case STAR: case SLASH: case PERCENT:
            if (ln && rn) return ValueKind.NUMBER;
        case SEQ: case SNE: case EQ: case NE: case LT: case LE: case GT: case GE:
            return ValueKind.BOOLEAN;
        default: break;
    }
    return ValueKind.UNKNOWN;
}

fn bool expression_is_int32(ast::Ast* tree, uint n) {
    return constant_facts != null && constant_facts.tree == tree
        && constant_facts.kinds != null && constant_facts.kinds[n] == ValueKind.INT32;
}

// Bound both retained strings and concatenation work. Exceeding any limit
// simply leaves the expression to ordinary generation.
const uint CONSTANT_STRING_COUNT = 128;
const uint CONSTANT_STRING_BYTES = 16384;
const uint CONSTANT_STRING_LENGTH = 1024;

tlocal ConstantFacts* constant_facts;

fn bool constant_truth(TVal value) {
    if (value.is_nullish()) return false;
    if (value.is_boolean()) return value.get_boolean();
    if (value.is_string()) return ((HString*)value.get_heapptr()).blen != 0;
    double number = value.get_number();
    return number != 0.0 && number == number;
}

// ToNumber is only called for facts whose tags are supported primitives;
// it cannot invoke user code or consult a global binding.
fn double constant_number(TVal value) {
    if (value.is_number()) return value.get_number();
    if (value.is_boolean()) return value.get_boolean() ? 1.0 : 0.0;
    if (value.is_null()) return 0.0;
    if (value.is_undefined()) return double::nan;
    return builtins::builtin_string_to_number((HString*)value.get_heapptr());
}

fn bool numeric_operation(NodeTag tag, TokenType op, TVal left, TVal right, TVal* result) {
    if (tag == NodeTag.UNARY) {
        switch (op) {
            case LOG_NOT: result.set_boolean(!constant_truth(left)); return true;
            case VOID: result.set_undefined(); return true;
            default: break;
        }
        double a = constant_number(left);
        switch (op) {
            case PLUS: result.set_number(a);
            case MINUS: result.set_number(-a);
            case BIT_NOT: result.set_number((double)~vm::toint32(a));
            default: return false;
        }
        return true;
    }
    double a = constant_number(left);
    double b = constant_number(right);
    // Each operation consumes exactly its AST children: never reassociate.
    switch (op) {
        case PLUS: result.set_number(a + b);
        case MINUS: result.set_number(a - b);
        case STAR: result.set_number(a * b);
        case SLASH: result.set_number(a / b);
        case PERCENT: result.set_number(a % b);
        case BIT_AND: result.set_number((double)(vm::toint32(a) & vm::toint32(b)));
        case BIT_OR: result.set_number((double)(vm::toint32(a) | vm::toint32(b)));
        case BIT_XOR: result.set_number((double)(vm::toint32(a) ^ vm::toint32(b)));
        case SHL: result.set_number((double)(int)((uint)vm::toint32(a) << ((uint)vm::toint32(b) & 31)));
        case SHR: result.set_number((double)(vm::toint32(a) >> ((uint)vm::toint32(b) & 31)));
        case USHR: result.set_number((double)((uint)vm::toint32(a) >> ((uint)vm::toint32(b) & 31)));
        case LT: result.set_boolean(a < b);
        case LE: result.set_boolean(a <= b);
        case GT: result.set_boolean(a > b);
        case GE: result.set_boolean(a >= b);
        case EQ:
        case SEQ: result.set_boolean(a == b);
        case NE:
        case SNE: result.set_boolean(a != b);
        default: return false;
    }
    return true;
}

fn bool ConstantFacts.string_fact(&self, char[] bytes, TVal* result) {
    if (bytes.len > CONSTANT_STRING_LENGTH) return false;
    // Normalize in bounded stack space before interning, so the heap's
    // optional normalization scratch allocation cannot affect equality.
    char[CONSTANT_STRING_LENGTH + CONSTANT_STRING_LENGTH / 2] normalized;
    if (hstring::has_raw_utf8_astral(bytes)) {
        uint length = hstring::normalize_to_cesu8(bytes, normalized[..]);
        if (length > CONSTANT_STRING_LENGTH) return false;
        bytes = normalized[:length];
    }
    for (uint i = 0; i < self.string_count; i++) {
        TVal value = self.string_roots[i].value;
        if (((HString*)value.get_heapptr()).equals(bytes)) {
            *result = value;
            return true;
        }
    }
    if (self.string_count == CONSTANT_STRING_COUNT
        || self.string_bytes + bytes.len > CONSTANT_STRING_BYTES) return false;
    if (self.string_roots == null) {
        self.string_roots = (ValueRoot*)self.heap.alloc_func(self.heap.heap_udata,
            CONSTANT_STRING_COUNT * ValueRoot::size);
        if (self.string_roots == null) return false;
    }
    HString* string = self.heap.str_intern_normalized(bytes);
    if (string == null) return false;
    result.set_string_borrowed(string);
    self.heap.push_value_root(&self.string_roots[self.string_count++], *result);
    self.string_bytes += (uint)bytes.len;
    return true;
}

// Return borrowed bytes, formatting numbers with the VM's dtoa mode. No
// managed allocation occurs while either concatenation operand is borrowed.
fn bool constant_string_bytes(TVal value, char[] scratch, char[]* bytes) {
    if (value.is_string()) { *bytes = ((HString*)value.get_heapptr()).get_data(); return true; }
    if (value.is_undefined()) { *bytes = "undefined"; return true; }
    if (value.is_null()) { *bytes = "null"; return true; }
    if (value.is_boolean()) { *bytes = value.get_boolean() ? "true" : "false"; return true; }
    double number = value.get_number();
    if (number != number) { *bytes = "NaN"; return true; }
    if (number == double::inf) { *bytes = "Infinity"; return true; }
    if (number == -double::inf) { *bytes = "-Infinity"; return true; }
    if (number == 0.0) { *bytes = "0"; return true; }
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int length = dtoa_bindings::boomkat_js_dtoa(scratch.ptr, number, 10, 0,
        dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
    if (length <= 0 || length >= scratch.len) return false;
    *bytes = scratch[:length];
    return true;
}

fn bool constant_equal(TVal left, TVal right, bool loose, bool* equal) {
    if (left.get_tag() == right.get_tag()) {
        *equal = vm::strict_eq(&left, &right);
        return true;
    }
    *equal = false;
    if (!loose) return true;
    if (left.is_nullish() || right.is_nullish()) {
        *equal = left.is_nullish() && right.is_nullish();
        return true;
    }
    if (left.is_boolean()) left.set_number(constant_number(left));
    if (right.is_boolean()) right.set_number(constant_number(right));
    // The runtime's loose-equality string parser differs from ToNumber for
    // some inputs. Fold only when both paths agree, leaving those cases intact.
    if (left.is_string() || right.is_string()) {
        TVal string = left.is_string() ? left : right;
        HString* text = (HString*)string.get_heapptr();
        double number = constant_number(string);
        double runtime_number = vm::hstring_to_number(text);
        if (!(number == runtime_number || (number != number && runtime_number != runtime_number))) return false;
    }
    *equal = constant_number(left) == constant_number(right);
    return true;
}

fn bool ConstantFacts.operation(&self, NodeTag tag, TokenType op, TVal left, TVal right, TVal* result) {
    if (tag == NodeTag.UNARY && op == TokenType.TYPEOF) {
        char[] type = left.is_undefined() ? "undefined" : left.is_null() ? "object"
            : left.is_boolean() ? "boolean" : left.is_string() ? "string" : "number";
        return self.string_fact(type, result);
    }
    if (tag == NodeTag.BINARY) {
        if (op == TokenType.SEQ || op == TokenType.SNE || op == TokenType.EQ || op == TokenType.NE) {
            bool equal;
            if (!constant_equal(left, right, op == TokenType.EQ || op == TokenType.NE, &equal)) return false;
            result.set_boolean(op == TokenType.SNE || op == TokenType.NE ? !equal : equal);
            return true;
        }
        if (op == TokenType.PLUS && (left.is_string() || right.is_string())) {
            char[64] left_scratch, right_scratch;
            char[] a, b;
            if (!constant_string_bytes(left, left_scratch[..], &a)
                || !constant_string_bytes(right, right_scratch[..], &b)
                || a.len + b.len > CONSTANT_STRING_LENGTH) return false;
            char[CONSTANT_STRING_LENGTH] buffer;
            mem::copy(&buffer[0], a.ptr, a.len);
            mem::copy(&buffer[0] + a.len, b.ptr, b.len);
            return self.string_fact(buffer[:a.len + b.len], result);
        }
        if ((op == TokenType.LT || op == TokenType.LE || op == TokenType.GT || op == TokenType.GE)
            && left.is_string() && right.is_string()) {
            int compare = hstring::hstring_compare((HString*)left.get_heapptr(), (HString*)right.get_heapptr());
            result.set_boolean(op == TokenType.LT ? compare < 0 : op == TokenType.LE ? compare <= 0
                : op == TokenType.GT ? compare > 0 : compare >= 0);
            return true;
        }
    }
    return numeric_operation(tag, op, left, right, result);
}

// Map reference nodes to the initializer of their resolved local const. A
// declaration in an ordinary block/function statement list dominates reads
// later in that list or its nested statements. Node order proves "later";
// binding/scope identity excludes shadows, prior TDZ reads, delayed closures,
// switch-case entry and per-iteration for-head initialization.
fn uint* local_constant_sources(ast::AstIndex* index, Heap* heap) {
    ast::Resolver* resolver = &index.res;
    ast::Ast* tree = &index.tree;
    bool candidate = false;
    for (uint b = 1; b < resolver.bindings.len; b++) {
        ast::Binding binding = resolver.bindings.data[b];
        if (binding.kind == ast::DeclKind.CONST && !binding.captured
            && resolver.scopes.data[resolver.scopes.data[binding.scope].func].kind == ast::ScopeKind.FUNCTION) {
            candidate = true;
            break;
        }
    }
    if (!candidate) return null;
    uint* sources = (uint*)heap.alloc_func(heap.heap_udata, (usz)tree.tags.len * uint::size);
    if (sources == null) return null;
    uint* initializers = (uint*)heap.alloc_func(heap.heap_udata, (usz)resolver.bindings.len * uint::size);
    if (initializers == null) { heap.free_func(heap.heap_udata, sources); return null; }
    defer heap.free_func(heap.heap_udata, initializers);
    mem::clear(sources, (sz)tree.tags.len * uint::size);
    mem::clear(initializers, (sz)resolver.bindings.len * uint::size);
    for (uint i = 1; i < resolver.sites.len; i++) {
        ast::Site site = resolver.sites.data[i];
        if (site.kind == ast::DeclKind.CONST && !site.pattern) sources[site.node] = site.binding;
    }
    for (uint n = 1; n < tree.tags.len; n++) {
        if (tree.tags.data[n] != NodeTag.VAR_DECL
            || (tree.flags.data[n] & ast::VAR_KIND_MASK) != ast::VAR_KIND_CONST) continue;
        uint declarations = tree.lhs.data[n];
        for (uint i = 0; i < tree.list_len(declarations); i++) {
            uint declaration = tree.list_item(declarations, i);
            uint pattern = tree.lhs.data[declaration];
            if (tree.tags.data[pattern] != NodeTag.IDENT) continue;
            uint binding = sources[pattern];
            if (binding == 0) continue;
            ast::Binding info = resolver.bindings.data[binding];
            if (info.kind != ast::DeclKind.CONST || info.captured) continue;
            ast::Scope scope = resolver.scopes.data[info.scope];
            if (scope.kind != ast::ScopeKind.FUNCTION && scope.kind != ast::ScopeKind.BLOCK) continue;
            ast::Scope function = resolver.scopes.data[scope.func];
            if (function.kind != ast::ScopeKind.FUNCTION
                || (function.flags & (ast::SCOPE_HAS_EVAL | ast::SCOPE_CAPTURE_ALL | ast::SCOPE_HAS_WITH)) != 0
                || (function.fn_flags & (ast::FNF_FIELD_INIT | ast::FNF_STATIC_BLOCK)) != 0) continue;
            bool dynamic = false;
            for (uint s = scope.parent; s != 0; s = resolver.scopes.data[s].parent) {
                if (resolver.scopes.data[s].kind == ast::ScopeKind.WITH) { dynamic = true; break; }
            }
            if (!dynamic) initializers[binding] = tree.rhs.data[declaration];
        }
    }
    mem::clear(sources, (sz)tree.tags.len * uint::size);
    for (uint i = 0; i < resolver.refs.len; i++) {
        ast::Ref reference = resolver.refs.data[i];
        if (tree.tags.data[reference.node] != NodeTag.IDENT) continue;
        uint from_function = resolver.scopes.data[reference.scope].func;
        for (uint s = reference.scope; s != 0; s = resolver.scopes.data[s].parent) {
            if (resolver.scopes.data[s].kind == ast::ScopeKind.WITH) break;
            uint binding = resolver.lookup(s, tree.lhs.data[reference.node]);
            if (binding == 0) continue;
            uint init = initializers[binding];
            if (init != 0 && init < reference.node && resolver.scopes.data[s].func == from_function) {
                sources[reference.node] = init;
            }
            break;
        }
    }
    return sources;
}

fn void ConstantFacts.begin(&self, ast::AstIndex* index, void* heap) {
    ast::Ast* tree = &index.tree;
    // The resolver retains reference scopes until this analysis has consumed
    // them. No generation path needs that temporary resolver vector afterward.
    defer index.res.refs.free();
    self.tree = tree;
    self.heap = (Heap*)heap;
    self.prev = constant_facts;
    constant_facts = self;
    if (g_disable_optimize) return;
    // Avoid a column for sources with no candidate operators at all.
    bool candidate = false;
    for (uint n = 1; n < tree.tags.len; n++) {
        NodeTag tag = tree.tags.data[n];
        if (tag == NodeTag.BINARY || tag == NodeTag.UNARY || tag == NodeTag.COND || tag == NodeTag.LOGICAL
            || (tag == NodeTag.VAR_DECL && (tree.flags.data[n] & ast::VAR_KIND_MASK) == ast::VAR_KIND_CONST)) {
            candidate = true;
            break;
        }
    }
    if (!candidate) return;
    self.values = (TVal*)self.heap.alloc_func(self.heap.heap_udata, (usz)tree.tags.len * TVal::size);
    // Allocation failure leaves the old, bounded recursive probe available.
    if (self.values == null) return;
    self.kinds = (ValueKind*)self.heap.alloc_func(self.heap.heap_udata, (usz)tree.tags.len * ValueKind::size);
    if (self.kinds != null) self.kinds[0] = ValueKind.UNKNOWN;
    uint* sources = local_constant_sources(index, self.heap);
    index.res.refs.free();
    defer if (sources != null) self.heap.free_func(self.heap.heap_udata, sources);
    self.values[0].set_deleted();
    for (uint n = 1; n < tree.tags.len; n++) {
        if (self.kinds != null) self.kinds[n] = expression_kind(tree, n, self.kinds);
        TVal* value = &self.values[n];
        value.set_deleted();
        NodeTag tag = tree.tags.data[n];
        switch (tag) {
            case NUMBER:
                value.set_number(bitcast(((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n], double));
            case STRING:
                self.string_fact(tree.atoms.get(tree.lhs.data[n]), value);
            case IDENT:
                if (sources != null && sources[n] != 0) *value = self.values[sources[n]];
            case TRUE_LIT: value.set_boolean(true);
            case FALSE_LIT: value.set_boolean(false);
            case NULL_LIT: value.set_null();
            case UNARY:
            case BINARY:
                TVal left = self.values[tree.lhs.data[n]];
                if (left.is_deleted()) continue;
                TVal right;
                if (tag == NodeTag.BINARY) {
                    right = self.values[tree.rhs.data[n]];
                    if (right.is_deleted()) continue;
                }
                self.operation(tag, (TokenType)(tree.flags.data[n] & 0x7F), left, right, value);
            case COND:
            case LOGICAL:
                uint selected = constant_selection(tree, n);
                if (selected != 0) *value = self.values[selected];
            default: break;
        }
    }
}

fn void ConstantFacts.end(&self) {
    // Entry points can release this column before finish() copies bytecode;
    // their deferred cleanup still handles errors on every earlier path.
    if (constant_facts != self) return;
    constant_facts = self.prev;
    for (uint i = self.string_count; i > 0;) self.heap.pop_value_root(&self.string_roots[--i]);
    if (self.string_roots != null) self.heap.free_func(self.heap.heap_udata, self.string_roots);
    self.string_roots = null;
    if (self.values != null) self.heap.free_func(self.heap.heap_udata, self.values);
    self.values = null;
    if (self.kinds != null) self.heap.free_func(self.heap.heap_udata, self.kinds);
    self.kinds = null;
}

fn bool constant_value(ast::Ast* tree, uint n, TVal* value) {
    if (constant_facts == null || constant_facts.tree != tree || constant_facts.values == null) return false;
    *value = constant_facts.values[n];
    return !value.is_deleted();
}

// Return the selected expression only when every omitted subtree is safe to
// skip. Unknown dead arms still go through ordinary generation/validation.
fn uint constant_selection(ast::Ast* tree, uint n) {
    TVal test;
    if (!constant_value(tree, tree.lhs.data[n], &test)) return 0;
    if (tree.tags.data[n] == NodeTag.COND) {
        uint rec = tree.rhs.data[n];
        bool yes = constant_truth(test);
        TVal ignored;
        if (!constant_value(tree, tree.field(rec, yes ? 1 : 0), &ignored)) return 0;
        return tree.field(rec, yes ? 0 : 1);
    }
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    bool right = op == TokenType.NULLISH ? test.is_nullish()
        : op == TokenType.LOG_AND ? constant_truth(test) : !constant_truth(test);
    if (right) return tree.rhs.data[n];
    TVal ignored;
    return constant_value(tree, tree.rhs.data[n], &ignored) ? tree.lhs.data[n] : 0;
}

// Operators produce values, not references or NamedEvaluation sites. Copying
// a selected local also keeps it stable across a later write to that local.
fn Val? CompilerContext.gen_selected_constant_arm(&self, uint n, uint selected) {
    self.gen_line_main(n);
    self.has_inferred_name = false;
    self.inferred_name = {};
    ushort result = self.alloc_reg();
    Val value = self.gen_expr(selected, 0)!;
    self.gen_line_end(n);
    self.emit_abc(Opcode.LDREG, (uint)result, (uint)value.reg, 0);
    self.free_val(value);
    if (self.call_prop_obj_reg != REG_NONE) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = REG_NONE;
    }
    return { result, false, 0 };
}

// Bound both recursion and repeated probes of overlapping subtrees. Failure
// leaves ordinary generation in charge, including all coercions and effects.
fn bool fold_number(ast::Ast* tree, uint n, uint* budget, TVal* result) {
    if (*budget == 0) return false;
    (*budget)--;
    NodeTag tag = tree.tags.data[n];
    if (tag == NodeTag.NUMBER) {
        result.set_number(bitcast(((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n], double));
        return true;
    }
    if (tag != NodeTag.BINARY && tag != NodeTag.UNARY) return false;
    TokenType op = (TokenType)(tree.flags.data[n] & 0x7F);
    TVal left;
    if (!fold_number(tree, tree.lhs.data[n], budget, &left) || !left.is_number()) return false;
    if (tag == NodeTag.UNARY) return numeric_operation(tag, op, left, left, result);
    TVal right;
    if (!fold_number(tree, tree.rhs.data[n], budget, &right) || !right.is_number()) return false;
    return numeric_operation(tag, op, left, right, result);
}

// Load a non-negative integer, an index or count the compiler computed, into
// `reg`: an LDINT immediate when it fits, otherwise a pool constant.
fn void CompilerContext.emit_load_index(&self, uint reg, uint value) {
    if (value <= bytecode::MAX_SBC) {
        self.emit_a_sbx(Opcode.LDINT, reg, (int)value);
    } else {
        self.emit_a_bc(Opcode.LDCONST, reg, self.add_number_constant((double)value));
    }
}

fn Val CompilerContext.gen_number(&self, double value) {
    ushort reg = self.alloc_reg();
    // Bounds precede conversion; negative zero must remain a double constant.
    if (value >= bytecode::MIN_SBC && value <= bytecode::MAX_SBC
        && (double)(int)value == value && (value != 0.0 || 1.0 / value > 0.0)) {
        self.emit_a_sbx(Opcode.LDINT, (uint)reg, (int)value);
    } else {
        self.emit_a_bc(Opcode.LDCONST, (uint)reg, self.add_number_constant(value));
    }
    return { reg, false, 0 };
}
