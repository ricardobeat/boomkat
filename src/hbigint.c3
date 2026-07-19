/// HBigInt — fixed-width 128-bit BigInt box.
///
/// This engine represents ECMAScript BigInt as a heap-allocated box holding a
/// native `int128` value.  It is NOT arbitrary precision: values outside the
/// range ±(2^127 − 1) are out of scope and the arithmetic paths raise a
/// RangeError instead of wrapping (so no wrong answers leak into results).
///
/// The box is a GC leaf: it has no outgoing references.  It lives on the
/// heap's mark-and-sweep `heap_allocated` list (like buffers) and is also
/// reference-counted, so a bigint held only by the constant pool survives via
/// its refcount and runtime-produced bigints are reclaimed by mark-and-sweep.
module duktape::hbigint;

import duktape::types;
import duktape::heap;

// ============================================================================
// Bounds
// ============================================================================

/// Largest representable BigInt: 2^127 − 1.
const int128 BIGINT_MAX = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
/// Smallest representable BigInt: −2^127.  Note the magnitude of BIGINT_MIN
/// exceeds BIGINT_MAX by one; negating BIGINT_MIN overflows and must throw.
const int128 BIGINT_MIN = (int128)0x80000000000000000000000000000000;

// ============================================================================
// HBigInt struct
// ============================================================================

/// A boxed 128-bit signed integer.  The header is HeapHeader-compatible so a
/// raw cast from HBigInt* to HeapHeader* reads the correct htype and GC bits.
struct HBigInt {
    HeapHeader header;
    int128     value;
}

// ============================================================================
// Allocation
// ============================================================================

/// Allocate a new HBigInt box holding `value` and register it with the heap's
/// mark-and-sweep tracking list.  The box starts with refcount 1 and is
/// flagged as a temporary root so an in-flight (non-safepoint) GC never frees
/// it before a register / constant slot anchors it.
///
/// Returns the new HBigInt or a fault on allocation failure.
fn HBigInt*? hbigint_alloc(Heap* hp, int128 value) {
    HBigInt tmp;
    void* raw = hp.alloc((usz)@sizeof(tmp))!;
    HBigInt* b = (HBigInt*)raw;
    // init() zeroes flags, sets refcount=1, and links the header at the head
    // of the heap_allocated list.
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

/// Extract the int128 value from a BigInt TVal.  The caller must have already
/// verified `tv.is_bigint()`.
macro int128 TVal.get_bigint(&self) {
    HBigInt* b = (HBigInt*)self.get_heapptr();
    return b.value;
}

// ============================================================================
// int128 ⇄ decimal / radix string conversion
// ============================================================================

/// Convert an int128 to a decimal string, writing into `buf` (which must be at
/// least 44 bytes: 39 digits + sign + NUL).  Returns the written slice.
fn char[] int128_to_decimal(int128 v, char[] buf) {
    return int128_to_radix(v, 10, buf);
}

/// Convert an int128 to a string in the given radix (2..36).  Writes into
/// `buf` (must be at least 130 bytes for binary of a 128-bit value + sign).
/// Returns the written slice.
fn char[] int128_to_radix(int128 v, uint radix, char[] buf) {
    if (v == 0) {
        buf[0] = '0';
        return buf[0:1];
    }

    // Work in the negative domain so BIGINT_MIN (whose magnitude has no
    // positive representation) is handled without overflow.
    bool neg = v < 0;
    int128 n = neg ? v : -v;   // n <= 0

    usz pos = buf.len;
    int128 r = (int128)radix;
    while (n != 0) {
        // n is <= 0; the remainder is <= 0.  Negate the digit to index.
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
// Checked arithmetic (overflow → fault, callers translate to RangeError)
// ============================================================================

/// Fault raised when a result exceeds ±(2^127 − 1).
faultdef BIGINT_OVERFLOW, BIGINT_DIV_ZERO, BIGINT_SYNTAX;

// ============================================================================
// Literal / string parsing
// ============================================================================

/// Parse a BigInt literal's digit text (as produced by the lexer, possibly
/// carrying a `0x`/`0o`/`0b` radix prefix and `_` separators) into an int128.
///
/// Overflow beyond ±(2^127 − 1) faults with BIGINT_OVERFLOW; malformed input
/// faults with BIGINT_SYNTAX.  Only non-negative magnitudes appear in literals
/// (the leading `-` of `-5n` is a separate unary operator).
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

/// Parse an unsigned magnitude in the given radix from `s` (may contain `_`
/// separators, already stripped of any radix prefix) into an int128, checking
/// against BIGINT_MAX at every step.
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
        // acc = acc * radix + d, with overflow checks against BIGINT_MAX.
        int128 scaled = bigint_mul(acc, r)!;
        acc = bigint_add(scaled, (int128)d)!;
    }
    if (!saw_digit) return BIGINT_SYNTAX~;
    return acc;
}

/// a + b with overflow detection (two's-complement sign rule).
fn int128? bigint_add(int128 a, int128 b) {
    int128 r = a + b;
    // Overflow iff operands share a sign and the result's sign differs.
    if (((a ^ r) & (b ^ r)) < 0) return BIGINT_OVERFLOW~;
    return r;
}

/// a − b with overflow detection.
fn int128? bigint_sub(int128 a, int128 b) {
    int128 r = a - b;
    // Overflow iff operands differ in sign and result's sign differs from a.
    if (((a ^ b) & (a ^ r)) < 0) return BIGINT_OVERFLOW~;
    return r;
}

/// −a with overflow detection (only BIGINT_MIN overflows).
fn int128? bigint_neg(int128 a) {
    if (a == BIGINT_MIN) return BIGINT_OVERFLOW~;
    return -a;
}

/// a * b with overflow detection via divide-back check.
fn int128? bigint_mul(int128 a, int128 b) {
    if (a == 0 || b == 0) return (int128)0;
    int128 r = a * b;
    // BIGINT_MIN * -1 overflows and also breaks the divide-back check.
    if ((a == BIGINT_MIN && b == -1) || (b == BIGINT_MIN && a == -1)) return BIGINT_OVERFLOW~;
    if (r / b != a) return BIGINT_OVERFLOW~;
    return r;
}

/// a / b (truncating toward zero, BigInt semantics).  b == 0 faults.
fn int128? bigint_div(int128 a, int128 b) {
    if (b == 0) return BIGINT_DIV_ZERO~;
    if (a == BIGINT_MIN && b == -1) return BIGINT_OVERFLOW~;
    return a / b;
}

/// a % b (result has the sign of a, BigInt semantics).  b == 0 faults.
fn int128? bigint_rem(int128 a, int128 b) {
    if (b == 0) return BIGINT_DIV_ZERO~;
    if (a == BIGINT_MIN && b == -1) return (int128)0;
    return a % b;
}

/// a ** b.  Negative exponent is a RangeError at the caller; here we assume
/// b >= 0.  Overflow at any step faults.
fn int128? bigint_pow(int128 a, int128 b) {
    if (b < 0) return BIGINT_OVERFLOW~;   // caller maps to RangeError separately
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
