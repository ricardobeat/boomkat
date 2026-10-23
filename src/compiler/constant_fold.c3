module boomkat::compiler;

import boomkat::ast;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;

// One temporary column per compilation unit, shared by all its function
// contexts. Undefined means unknown (undefined expressions are not analysed).
// Only primitive, effect-free syntax receives a fact: knowing a runtime value
// alone would not justify omitting generation's remaining early-error checks.
struct ConstantFacts {
    ast::Ast* tree;
    TVal* values;
    ConstantFacts* prev;
    Heap* heap;
}

tlocal ConstantFacts* constant_facts;

fn bool constant_truth(TVal value) {
    if (value.is_null()) return false;
    if (value.is_boolean()) return value.get_boolean();
    double number = value.get_number();
    return number != 0.0 && number == number;
}

fn bool numeric_operation(NodeTag tag, TokenType op, TVal left, TVal right, TVal* result) {
    if (tag == NodeTag.UNARY && op == TokenType.LOG_NOT) {
        result.set_boolean(!constant_truth(left));
        return true;
    }
    if (!left.is_number()) return false;
    double a = left.get_number();
    if (tag == NodeTag.UNARY) {
        switch (op) {
            case PLUS: result.set_number(a);
            case MINUS: result.set_number(-a);
            default: return false;
        }
        return true;
    }
    if (!right.is_number()) return false;
    double b = right.get_number();
    // Each operation consumes exactly its AST children: never reassociate.
    switch (op) {
        case PLUS: result.set_number(a + b);
        case MINUS: result.set_number(a - b);
        case STAR: result.set_number(a * b);
        case SLASH: result.set_number(a / b);
        case PERCENT: result.set_number(a % b);
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

fn void ConstantFacts.begin(&self, ast::Ast* tree, void* heap) {
    self.tree = tree;
    self.heap = (Heap*)heap;
    self.prev = constant_facts;
    constant_facts = self;
    if (g_disable_optimize) return;
    // Avoid a column for sources with no candidate operators at all.
    bool candidate = false;
    for (uint n = 1; n < tree.tags.len; n++) {
        NodeTag tag = tree.tags.data[n];
        if (tag == NodeTag.BINARY || tag == NodeTag.UNARY || tag == NodeTag.COND || tag == NodeTag.LOGICAL) {
            candidate = true;
            break;
        }
    }
    if (!candidate) return;
    self.values = (TVal*)self.heap.alloc_func(self.heap.heap_udata, (usz)tree.tags.len * TVal::size);
    // Allocation failure leaves the old, bounded recursive probe available.
    if (self.values == null) return;
    self.values[0].set_undefined();
    for (uint n = 1; n < tree.tags.len; n++) {
        TVal* value = &self.values[n];
        value.set_undefined();
        NodeTag tag = tree.tags.data[n];
        switch (tag) {
            case NUMBER:
                value.set_number(bitcast(((ulong)tree.rhs.data[n] << 32) | (ulong)tree.lhs.data[n], double));
            case TRUE_LIT: value.set_boolean(true);
            case FALSE_LIT: value.set_boolean(false);
            case NULL_LIT: value.set_null();
            case UNARY:
            case BINARY:
                TVal left = self.values[tree.lhs.data[n]];
                if (left.is_undefined()) continue;
                TVal right;
                if (tag == NodeTag.BINARY) {
                    right = self.values[tree.rhs.data[n]];
                    if (right.is_undefined()) continue;
                }
                numeric_operation(tag, (TokenType)(tree.flags.data[n] & 0x7F), left, right, value);
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
    if (self.values != null) self.heap.free_func(self.heap.heap_udata, self.values);
    self.values = null;
}

fn bool constant_value(ast::Ast* tree, uint n, TVal* value) {
    if (constant_facts == null || constant_facts.tree != tree || constant_facts.values == null) return false;
    *value = constant_facts.values[n];
    return !value.is_undefined();
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
    bool right = op == TokenType.NULLISH ? test.is_null()
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
