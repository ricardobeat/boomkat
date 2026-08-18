/// HBigInt, a fixed-width 128-bit BigInt box.
///
/// ECMAScript BigInt is represented here as a heap box around a native `int128`,
/// so it is bounded rather than arbitrary precision. Arithmetic that would leave
/// the range of a signed 128-bit integer raises a RangeError instead of
/// wrapping, which keeps wrong answers out of results.
///
/// The box holds no references, making it a GC leaf. It sits on the heap's
/// `heap_allocated` list like a buffer and is refcounted too, so a bigint held
/// only by the constant pool survives on its refcount while runtime-produced
/// ones are reclaimed by mark-and-sweep.
module boomkat::hbigint;

import boomkat::types;
import boomkat::heap;

// ============================================================================
// Bounds
// ============================================================================

/// Largest representable BigInt, 2^127 - 1.
const int128 BIGINT_MAX = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
/// Smallest representable BigInt, -2^127. Its magnitude is one greater than
/// BIGINT_MAX, so negating it overflows and must throw.
const int128 BIGINT_MIN = (int128)0x80000000000000000000000000000000;

// ============================================================================
// HBigInt struct
// ============================================================================

/// A boxed 128-bit signed integer. The header is HeapHeader-compatible, so a raw
/// cast to HeapHeader* reads the right htype and GC bits.
struct HBigInt {
    HeapHeader header;
    int128     value;
}

// ============================================================================
// Allocation
// ============================================================================

/// Allocate an HBigInt holding `value` and add it to the heap's tracking list.
/// It starts at refcount 1 and is a temporary root, so a collection outside a
/// safepoint cannot free it before a register or constant slot anchors it.
///
/// Returns the new box, or a fault if allocation fails.
fn HBigInt*? hbigint_alloc(Heap* hp, int128 value) {
    HBigInt tmp;
    void* raw = hp.alloc((usz)@sizeof(tmp))!;
    HBigInt* b = (HBigInt*)raw;
    // init() zeroes the flags, sets refcount to 1, and links the header at the
    // head of heap_allocated.
    b.header.init(HType.BIGINT, &hp.heap_allocated);
    b.header.set_temproot();
    b.value = value;
    hp.live_obj_count++;
    if (hp.live_obj_count > hp.peak_live_obj_count) {
        hp.peak_live_obj_count = hp.live_obj_count;
    }
    return b;
}

// ============================================================================
// TVal integration
// ============================================================================

/// The int128 inside a BigInt TVal. Callers must have checked `is_bigint()`.
macro int128 TVal.get_bigint(&self) {
    HBigInt* b = (HBigInt*)self.get_heapptr();
    return b.value;
}

// ============================================================================
// Conversion between int128 and decimal or radix strings
// ============================================================================

/// Write an int128 to `buf` as decimal and return the written slice. `buf` needs
/// 44 bytes: 39 digits, a sign, and a NUL.
fn char[] int128_to_decimal(int128 v, char[] buf) {
    return int128_to_radix(v, 10, buf);
}

/// Write an int128 to `buf` in a radix from 2 to 36 and return the written
/// slice. `buf` needs 130 bytes, enough for a 128-bit value in binary plus a sign.
fn char[] int128_to_radix(int128 v, uint radix, char[] buf) {
    if (v == 0) {
        buf[0] = '0';
        return buf[0:1];
    }

    // Working in the negative domain keeps BIGINT_MIN, whose magnitude has no
    // positive representation, from overflowing.
    bool neg = v < 0;
    int128 n = neg ? v : -v;   // n <= 0

    usz pos = buf.len;
    int128 r = (int128)radix;
    while (n != 0) {
        // n is negative, so the remainder is too, and the digit needs negating.
        int128 digit = -(n % r);
        n = n / r;
        char c = (char)(int)digit;
        buf[--pos] = c < 10 ? (char)('0' + c) : (char)('a' + (c - 10));
    }
    if (neg) {
        buf[--pos] = '-';
    }
    // Shift the produced bytes to the front of the buffer.
    usz len = buf.len - pos;
    for (usz i = 0; i < len; i++) {
        buf[i] = buf[pos + i];
    }
    return buf[0:len];
}

// ============================================================================
// Checked arithmetic, where overflow faults and callers raise a RangeError
// ============================================================================

/// Raised when a result leaves the representable range.
faultdef BIGINT_OVERFLOW, BIGINT_DIV_ZERO, BIGINT_SYNTAX;

// ============================================================================
// Literal / string parsing
// ============================================================================

/// Parse a BigInt literal's digit text into an int128. The lexer may hand this a
/// `0x`, `0o`, or `0b` prefix and `_` separators.
///
/// Overflow faults with BIGINT_OVERFLOW and malformed input with BIGINT_SYNTAX.
/// Literals are always non-negative, since the `-` in `-5n` is a unary operator.
fn int128? parse_bigint_literal(char[] digits) {
    usz i = 0;
    usz n = digits.len;
    uint radix = 10;
    if (n >= 2 && digits[0] == '0') {
        char p = digits[1];
        if (p == 'x' || p == 'X') { radix = 16; i = 2; }
        else if (p == 'o' || p == 'O') { radix = 8; i = 2; }
        else if (p == 'b' || p == 'B') { radix = 2; i = 2; }
    }
    return parse_int128_radix(digits[i..], radix);
}

/// Parse an unsigned magnitude in the given radix into an int128, checking for
/// overflow at every step. `s` has had any radix prefix stripped and may still
/// contain `_` separators.
fn int128? parse_int128_radix(char[] s, uint radix) {
    int128 acc = 0;
    int128 r = (int128)radix;
    bool saw_digit = false;
    foreach (char c : s) {
        if (c == '_') continue;
        int d;
        if (c >= '0' && c <= '9') { d = c - '0'; }
        else if (c >= 'a' && c <= 'z') { d = c - 'a' + 10; }
        else if (c >= 'A' && c <= 'Z') { d = c - 'A' + 10; }
        else { return BIGINT_SYNTAX~; }
        if ((uint)d >= radix) return BIGINT_SYNTAX~;
        saw_digit = true;
        // acc = acc * radix + d, with both steps checked.
        int128 scaled = bigint_mul(acc, r)!;
        acc = bigint_add(scaled, (int128)d)!;
    }
    if (!saw_digit) return BIGINT_SYNTAX~;
    return acc;
}

/// a + b, faulting on overflow.
fn int128? bigint_add(int128 a, int128 b) {
    int128 r = a + b;
    // Overflow exactly when both operands share a sign the result does not.
    if (((a ^ r) & (b ^ r)) < 0) return BIGINT_OVERFLOW~;
    return r;
}

/// a - b, faulting on overflow.
fn int128? bigint_sub(int128 a, int128 b) {
    int128 r = a - b;
    // Overflow exactly when the operands differ in sign and the result's sign
    // differs from a's.
    if (((a ^ b) & (a ^ r)) < 0) return BIGINT_OVERFLOW~;
    return r;
}

/// Negate a. Only BIGINT_MIN overflows.
fn int128? bigint_neg(int128 a) {
    if (a == BIGINT_MIN) return BIGINT_OVERFLOW~;
    return -a;
}

/// a * b, faulting on overflow, which a divide-back detects.
fn int128? bigint_mul(int128 a, int128 b) {
    if (a == 0 || b == 0) return (int128)0;
    int128 r = a * b;
    // BIGINT_MIN * -1 overflows, and would also break the divide-back check.
    if ((a == BIGINT_MIN && b == -1) || (b == BIGINT_MIN && a == -1)) return BIGINT_OVERFLOW~;
    if (r / b != a) return BIGINT_OVERFLOW~;
    return r;
}

/// a / b, truncating toward zero as BigInt requires. A zero divisor faults.
fn int128? bigint_div(int128 a, int128 b) {
    if (b == 0) return BIGINT_DIV_ZERO~;
    if (a == BIGINT_MIN && b == -1) return BIGINT_OVERFLOW~;
    return a / b;
}

/// a % b, taking the sign of a as BigInt requires. A zero divisor faults.
fn int128? bigint_rem(int128 a, int128 b) {
    if (b == 0) return BIGINT_DIV_ZERO~;
    if (a == BIGINT_MIN && b == -1) return (int128)0;
    return a % b;
}

/// a ** b for a non-negative b. The caller turns a negative exponent into a
/// RangeError. Overflow at any step faults.
fn int128? bigint_pow(int128 a, int128 b) {
    if (b < 0) return BIGINT_OVERFLOW~;
    int128 result = 1;
    int128 base = a;
    int128 exp = b;
    while (exp > 0) {
        if ((exp & 1) != 0) {
            result = bigint_mul(result, base)!;
        }
        exp = exp >> 1;
        if (exp > 0) {
            base = bigint_mul(base, base)!;
        }
    }
    return result;
}
