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

// Store a freshly computed int128 into destination register `ra` as a boxed
// BigInt, with correct refcounting.  On allocation failure raises a RangeError
// (out of memory is surfaced the same as overflow here) and returns false.
fn bool vm_set_reg_bigint(Vm* vm, TVal* ra, int128 value) {
    hbigint::HBigInt*? box_r = hbigint::hbigint_alloc(vm.heap, value);
    if (catch box_r) {
        vm_set_range_error(vm, "BigInt allocation failed");
        return false;
    }
    hbigint::HBigInt* box = box_r;
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

    int128 a = pb.get_bigint();
    int128 b = pc.get_bigint();
    int128? r;

    switch (op) {
        case Opcode.ADD: r = hbigint::bigint_add(a, b);
        case Opcode.SUB: r = hbigint::bigint_sub(a, b);
        case Opcode.MUL: r = hbigint::bigint_mul(a, b);
        case Opcode.DIV: r = hbigint::bigint_div(a, b);
        case Opcode.MOD: r = hbigint::bigint_rem(a, b);
        case Opcode.EXP:
            if (b < 0) {
                vm_set_range_error(vm, "Exponent must be non-negative");
                return BigIntOpResult.THREW;
            }
            r = hbigint::bigint_pow(a, b);
        case Opcode.BAND: r = a & b;
        case Opcode.BOR:  r = a | b;
        case Opcode.BXOR: r = a ^ b;
        case Opcode.SHL:  r = vm_bigint_shl(a, b);
        case Opcode.SHR:  r = vm_bigint_shr(a, b);
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
            vm_set_range_error(vm, "BigInt value exceeds supported precision");
        }
        return BigIntOpResult.THREW;
    }
    if (!vm_set_reg_bigint(vm, ra, r)) return BigIntOpResult.THREW;
    return BigIntOpResult.HANDLED;
}

// BigInt left shift with overflow checking (fixed-width int128).  A negative
// count shifts right (arithmetic).  Shifting a nonzero value out of the
// 128-bit range is an overflow (RangeError at the caller).
fn int128? vm_bigint_shl(int128 v, int128 count) {
    if (count == 0) return v;
    if (count < 0) {
        // Right shift: arithmetic, saturates toward 0 / -1. Test the magnitude
        // against −128 directly rather than negating `count`: `-count` would
        // overflow (UB) when count == BIGINT_MIN and wrongly stay negative,
        // skipping the saturation guard.
        if (count <= (int128)-128) return v < 0 ? (int128)-1 : (int128)0;
        uint n = (uint)(-count);
        return v >> (uint128)n;
    }
    // Left shift.
    if (v == 0) return (int128)0;
    if (count >= 128) return hbigint::BIGINT_OVERFLOW~;
    uint sh = (uint)count;
    int128 r = v << (uint128)sh;
    // Overflow iff shifting back does not recover the original value.
    if ((r >> (uint128)sh) != v) return hbigint::BIGINT_OVERFLOW~;
    return r;
}

// BigInt `>>` (v >> count). Positive count is an arithmetic right shift
// (saturating toward 0 / -1 at ≥128); a negative count is a left shift by
// |count|. Mirror of `vm_bigint_shl` with the sign flipped, testing the
// magnitude against +128 directly so `count == BIGINT_MIN` never negates.
fn int128? vm_bigint_shr(int128 v, int128 count) {
    if (count == 0) return v;
    if (count > 0) {
        if (count >= 128) return v < 0 ? (int128)-1 : (int128)0;
        return v >> (uint128)(uint)count;
    }
    // count < 0: left shift by |count|. `-count` is safe here (count != MIN
    // would only matter for a positive magnitude, and MIN is handled by the
    // >= 128 overflow bound below via the direct -128 comparison).
    if (v == 0) return (int128)0;
    if (count <= (int128)-128) return hbigint::BIGINT_OVERFLOW~;
    uint sh = (uint)(-count);
    int128 r = v << (uint128)sh;
    if ((r >> (uint128)sh) != v) return hbigint::BIGINT_OVERFLOW~;
    return r;
}

// Compute BigInt increment/decrement of `v`.  Overflow faults.
fn int128? bigint_step(int128 v, bool inc) {
    return inc ? hbigint::bigint_add(v, (int128)1) : hbigint::bigint_sub(v, (int128)1);
}

// ============================================================================
// Unary
// ============================================================================

// Increment or decrement an owned BigInt register in place.  `slot` must
// currently hold a BigInt (its box reference is released and replaced).
// Overflow raises RangeError.
fn BigIntOpResult vm_bigint_incdec(Vm* vm, TVal* slot, bool inc) {
    int128? r = bigint_step(slot.get_bigint(), inc);
    if (catch r) {
        vm_set_range_error(vm, "BigInt value exceeds supported precision");
        return BigIntOpResult.THREW;
    }
    if (!vm_set_reg_bigint(vm, slot, r)) return BigIntOpResult.THREW;
    return BigIntOpResult.HANDLED;
}

// Attempt a BigInt unary negation (UNM) or bitwise-not (BNOT).  Returns
// NOT_BIGINT when the operand is not a BigInt.
fn BigIntOpResult vm_bigint_unary(Vm* vm, Opcode op, TVal* ra, TVal* operand) {
    if (!operand.is_bigint()) return BigIntOpResult.NOT_BIGINT;
    int128 a = operand.get_bigint();
    int128? r;
    switch (op) {
        case Opcode.UNM: r = hbigint::bigint_neg(a);
        case Opcode.BNOT: r = ~a;
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
        int128 a = x.get_bigint();
        int128 b = y.get_bigint();
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
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
            int128? yb = string_to_bigint(ys.get_data());
            if (catch yb) { *is_undef = true; return 0; }
            int128 a = x.get_bigint();
            if (a < yb) return -1;
            if (a > yb) return 1;
            return 0;
        }
        // ES2020 §7.1.3 ToNumeric(Boolean): true -> 1, false -> 0.
        double num = y.is_boolean() ? (y.get_boolean() ? 1.0 : 0.0) : y.get_number_or_fastint();
        int c = vm_bigint_cmp_number(x.get_bigint(), num);
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
        int128? xb = string_to_bigint(xs.get_data());
        if (catch xb) { *is_undef = true; return 0; }
        int128 b = y.get_bigint();
        if (xb < b) return -1;
        if (xb > b) return 1;
        return 0;
    }
    double num = x.is_boolean() ? (x.get_boolean() ? 1.0 : 0.0) : x.get_number_or_fastint();
    int c = vm_bigint_cmp_number(y.get_bigint(), num);
    if (c == 2) { *is_undef = true; return 0; }
    // c is (big <=> num) = (y <=> x); invert to get (x <=> y).
    return -c;
}

// Compare a BigInt against a Number by mathematical value.  `big` is the
// BigInt's int128; `num` is the numeric operand.  Returns -1 / 0 / 1
// (big < num / == / >), or 2 when the comparison is "undefined" because
// `num` is NaN.
fn int vm_bigint_cmp_number(int128 big, double num) {
    if (num != num) return 2;   // NaN
    // Compare int128 (big) against a double (num) without precision loss for
    // the common integral cases; fall back to double conversion otherwise.
    double bf = (double)big;
    if (bf < num) return -1;
    if (bf > num) return 1;
    // bf == num as doubles: refine using the truncated integer part of num
    // when num is finite and integral within int128 range.
    if (num >= -1.7014118346046923e38 && num <= 1.7014118346046923e38) {
        int128 ni = (int128)num;
        if ((double)ni == num) {
            if (big < ni) return -1;
            if (big > ni) return 1;
            return 0;
        }
        // num has a fractional part equal (as double) to big: big vs num.
        // big == floor-ish; if num > ni then big < num, else big > num.
        if (num > (double)ni) return -1;
        return 1;
    }
    return 0;
}
