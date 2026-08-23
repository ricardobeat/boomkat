// BigInt operand handling for the arithmetic, bitwise, and
// comparison opcodes.
//
// The hot number paths in Vm.run call into these helpers only after checking
// that at least one operand is a BigInt, so the common numeric case pays
// nothing.  Arithmetic on two BigInts is done in native int128 (fixed width);
// out-of-range results and division/modulo by zero raise the appropriate
// error via the deferred-throw mechanism (vm.throw_pending).
module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hbigint;
import std::math;

// ============================================================================
// Result of a BigInt binary-op attempt.
// ============================================================================

// Outcome of vm_bigint_binop / vm_bigint_relcompare.
enum BigIntOpResult : char {
    NOT_BIGINT,   // Neither operand was a BigInt, so the caller falls through.
    HANDLED,      // The result is in the destination register; continue.
    THREW,        // A deferred throw was raised and must be propagated.
}

// ============================================================================
// Register store
// ============================================================================

// Store a freshly computed BigInt box into destination register `ra` with
// correct refcounting. A null box means the operation could not allocate, which
// surfaces as a RangeError just as an over-large result does.
fn bool vm_set_reg_bigint(Vm* vm, TVal* ra, hbigint::HBigInt* box) {
    if (box == null) {
        vm_set_range_error(vm, "BigInt allocation failed");
        return false;
    }
    // set_bigint increfs (→ refcount 2: alloc's ref + register ref).  Release
    // the register's old value, then drop the alloc's initial reference so the
    // register slot holds exactly one.
    vm.heap.decref_tval(ra);
    ra.set_bigint(box);
    vm.heap.decref((types::HeapHeader*)box);
    return true;
}

// ============================================================================
// Arithmetic / bitwise binary ops
// ============================================================================

// Attempt a BigInt binary arithmetic / bitwise op.
//
// Contract (ES2020 §12 numeric operations):
//   - Both operands BigInt → compute in int128; overflow / divide-by-zero
//     raise RangeError.
//   - Exactly one operand BigInt (the other Number/anything) → TypeError
//     ("Cannot mix BigInt and other types").
//   - Neither operand BigInt → NOT_BIGINT (caller handles the numeric path).
fn BigIntOpResult vm_bigint_binop(Vm* vm, Opcode op, TVal* ra, TVal* rb, TVal* rc) {
    // ES2020 §13.15.3: ToPrimitive(hint number) both operands first, so a
    // wrapper / @@toPrimitive that yields a BigInt participates as a BigInt.
    TVal pb = *rb;
    TVal pc = *rc;
    if (pb.is_object()) {
        pb = to_primitive_value(vm, rb, 2);
        if (vm.throw_pending) return BigIntOpResult.THREW;
    }
    if (pc.is_object()) {
        pc = to_primitive_value(vm, rc, 2);
        if (vm.throw_pending) return BigIntOpResult.THREW;
    }

    bool b_big = pb.is_bigint();
    bool c_big = pc.is_bigint();
    if (!b_big && !c_big) return BigIntOpResult.NOT_BIGINT;
    if (b_big != c_big) {
        vm_set_type_error(vm, "Cannot mix BigInt and other types, use explicit conversions");
        return BigIntOpResult.THREW;
    }

    hbigint::HBigInt* a = pb.get_bigint();
    hbigint::HBigInt* b = pc.get_bigint();
    Heap* hp = vm.heap;
    hbigint::HBigInt*? r;

    switch (op) {
        case Opcode.ADD: r = hbigint::hbigint_addsub(hp, a, b, false);
        case Opcode.SUB: r = hbigint::hbigint_addsub(hp, a, b, true);
        case Opcode.MUL: r = hbigint::hbigint_mul(hp, a, b);
        case Opcode.DIV: {
            hbigint::HBigInt* q;
            if (catch hbigint::hbigint_divrem(hp, a, b, &q, null)) {
                vm_set_range_error(vm, "Division by zero");
                return BigIntOpResult.THREW;
            }
            r = q;
        }
        case Opcode.MOD: {
            hbigint::HBigInt* rem;
            if (catch hbigint::hbigint_divrem(hp, a, b, null, &rem)) {
                vm_set_range_error(vm, "Division by zero");
                return BigIntOpResult.THREW;
            }
            r = rem;
        }
        case Opcode.EXP:
            if (b.is_negative()) {
                vm_set_range_error(vm, "Exponent must be non-negative");
                return BigIntOpResult.THREW;
            }
            r = hbigint::hbigint_pow(hp, a, b);
        case Opcode.BAND: r = hbigint::hbigint_bitop(hp, a, b, hbigint::BitOp.AND);
        case Opcode.BOR:  r = hbigint::hbigint_bitop(hp, a, b, hbigint::BitOp.OR);
        case Opcode.BXOR: r = hbigint::hbigint_bitop(hp, a, b, hbigint::BitOp.XOR);
        case Opcode.SHL:  r = vm_bigint_shift(hp, a, b, false);
        case Opcode.SHR:  r = vm_bigint_shift(hp, a, b, true);
        case Opcode.USHR:
            // ES2020: unsigned right shift is not defined for BigInt.
            vm_set_type_error(vm, "BigInts have no unsigned right shift, use >> instead");
            return BigIntOpResult.THREW;
        default:
            // Any other op reaching here with BigInt operands is unsupported.
            vm_set_type_error(vm, "Cannot use BigInt operand with this operator");
            return BigIntOpResult.THREW;
    }

    if (catch excuse = r) {
        if (excuse == hbigint::BIGINT_DIV_ZERO) {
            vm_set_range_error(vm, "Division by zero");
        } else {
            vm_set_range_error(vm, "BigInt is too large to allocate");
        }
        return BigIntOpResult.THREW;
    }
    if (!vm_set_reg_bigint(vm, ra, r)) return BigIntOpResult.THREW;
    return BigIntOpResult.HANDLED;
}

// BigInt shift. `right` selects >> ; a negative count reverses the direction,
// as ECMAScript defines `a << -n` to be `a >> n` and vice versa.
//
// A left shift can only fail by exhausting memory: the result is exact at any
// width. A right shift always succeeds, saturating to 0 or -1 once every bit
// has been shifted out.
fn hbigint::HBigInt*? vm_bigint_shift(Heap* hp, hbigint::HBigInt* v,
                                      hbigint::HBigInt* count, bool right) {
    // Resolve the effective direction first: `>>` reverses it, and so does a
    // negative count, so the two cancel when both apply.
    bool neg = count.is_negative();
    bool shift_right = right != neg;

    // A count too large to hold is either an immediate out-of-memory (left) or
    // a shift that pushes every bit out (right), which saturates to 0 or -1.
    if (!count.fits_shift_count()) {
        if (!shift_right) return hbigint::BIGINT_OVERFLOW~;
        return hbigint::hbigint_shr(hp, v, 1 << 30);
    }
    long n = count.to_shift_count();
    return shift_right ? hbigint::hbigint_shr(hp, v, n) : hbigint::hbigint_shl(hp, v, n);
}

// v +/- 1. Fails only when the result cannot be allocated.
fn hbigint::HBigInt*? bigint_step(Heap* hp, hbigint::HBigInt* v, bool inc) {
    hbigint::HBigInt* one = hbigint::hbigint_from_slimb(hp, 1)!;
    return hbigint::hbigint_addsub(hp, v, one, !inc);
}

// ============================================================================
// Unary
// ============================================================================

// Increment or decrement an owned BigInt register in place.  `slot` must
// currently hold a BigInt (its box reference is released and replaced).
// Overflow raises RangeError.
fn BigIntOpResult vm_bigint_incdec(Vm* vm, TVal* slot, bool inc) {
    hbigint::HBigInt*? r = bigint_step(vm.heap, slot.get_bigint(), inc);
    if (catch r) {
        vm_set_range_error(vm, "BigInt is too large to allocate");
        return BigIntOpResult.THREW;
    }
    if (!vm_set_reg_bigint(vm, slot, r)) return BigIntOpResult.THREW;
    return BigIntOpResult.HANDLED;
}

// Attempt a BigInt unary negation (UNM) or bitwise-not (BNOT).  Returns
// NOT_BIGINT when the operand is not a BigInt.
fn BigIntOpResult vm_bigint_unary(Vm* vm, Opcode op, TVal* ra, TVal* operand) {
    if (!operand.is_bigint()) return BigIntOpResult.NOT_BIGINT;
    hbigint::HBigInt* a = operand.get_bigint();
    hbigint::HBigInt*? r;
    switch (op) {
        case Opcode.UNM: r = hbigint::hbigint_neg(vm.heap, a);
        case Opcode.BNOT: r = hbigint::hbigint_not(vm.heap, a);
        case Opcode.UNP:
            // ES2020 §12.5.4: unary + on a BigInt throws TypeError.
            vm_set_type_error(vm, "Cannot convert a BigInt value to a number");
            return BigIntOpResult.THREW;
        default:
            vm_set_type_error(vm, "Cannot use BigInt operand with this operator");
            return BigIntOpResult.THREW;
    }
    if (catch r) {
        vm_set_range_error(vm, "BigInt value exceeds supported precision");
        return BigIntOpResult.THREW;
    }
    if (!vm_set_reg_bigint(vm, ra, r)) return BigIntOpResult.THREW;
    return BigIntOpResult.HANDLED;
}

// ============================================================================
// Relational comparison (mathematical value; mixes BigInt with Number)
// ============================================================================

// Relational comparison where at least one primitive operand is a BigInt.
// Returns -1 / 0 / 1 (x < y / == / >).  Sets *is_undef when the result is
// undefined (a NaN number operand, or a string that is not a valid BigInt).
fn int vm_bigint_relational(Vm* vm, TVal* x, TVal* y, bool* is_undef) {
    *is_undef = false;
    bool x_big = x.is_bigint();
    bool y_big = y.is_bigint();

    if (x_big && y_big) {
        return hbigint::hbigint_cmp(x.get_bigint(), y.get_bigint());
    }

    if (x_big) {
        // BigInt <=> (Number | String | Boolean | Symbol)
        if (y.is_string()) {
            HString* ys = (HString*)y.get_heapptr();
            // Symbols share the STRING tag but can never be implicitly
            // converted to a number (ES2020 §7.1.3), so throw rather than compare.
            if (ys != null && ys.is_symbol()) {
                vm_set_type_error(vm, "Cannot convert a Symbol value to a number");
                return 0;
            }
            hbigint::HBigInt*? yb = string_to_bigint(vm.heap, ys.get_data());
            if (catch yb) { *is_undef = true; return 0; }
            return hbigint::hbigint_cmp(x.get_bigint(), yb);
        }
        // ES2020 §7.1.3 ToNumeric(Boolean): true -> 1, false -> 0.
        double num = y.is_boolean() ? (y.get_boolean() ? 1.0 : 0.0) : y.get_number_or_fastint();
        int c = vm_bigint_cmp_number(vm.heap, x.get_bigint(), num);
        if (c == 2) { *is_undef = true; return 0; }
        return c;
    }

    // y is BigInt, x is Number | String | Boolean | Symbol
    if (x.is_string()) {
        HString* xs = (HString*)x.get_heapptr();
        if (xs != null && xs.is_symbol()) {
            vm_set_type_error(vm, "Cannot convert a Symbol value to a number");
            return 0;
        }
        hbigint::HBigInt*? xb = string_to_bigint(vm.heap, xs.get_data());
        if (catch xb) { *is_undef = true; return 0; }
        return hbigint::hbigint_cmp(xb, y.get_bigint());
    }
    double num = x.is_boolean() ? (x.get_boolean() ? 1.0 : 0.0) : x.get_number_or_fastint();
    int c = vm_bigint_cmp_number(vm.heap, y.get_bigint(), num);
    if (c == 2) { *is_undef = true; return 0; }
    // c is (big <=> num) = (y <=> x); invert to get (x <=> y).
    return -c;
}

// Compare a BigInt against a Number by mathematical value.  `big` is the
// BigInt's int128; `num` is the numeric operand.  Returns -1 / 0 / 1
// (big < num / == / >), or 2 when the comparison is "undefined" because
// `num` is NaN.
fn int vm_bigint_cmp_number(Heap* hp, hbigint::HBigInt* big, double num) {
    if (num != num) return 2;   // NaN
    if (math::is_inf(num)) return num > 0 ? -1 : 1;
    // Compare through doubles first. That is exact whenever the BigInt is
    // within 2^53; beyond it, rounding can make unequal values compare equal,
    // so an apparent tie is re-checked against the number's integer part.
    double bf = big.to_double();
    if (bf < num) return -1;
    if (bf > num) return 1;
    // Tie as doubles. Convert num's integral part to a BigInt and compare
    // exactly, then let any fractional part break the remaining tie.
    double trunc_num = num < 0 ? -math::floor(-num) : math::floor(num);
    hbigint::HBigInt*? ni = hbigint::hbigint_from_double(hp, trunc_num);
    if (catch ni) return 0;
    int c = hbigint::hbigint_cmp(big, ni);
    if (c != 0) return c;
    // Equal to the integer part: a positive fraction makes num the larger.
    if (num > trunc_num) return -1;
    if (num < trunc_num) return 1;
    return 0;
}

