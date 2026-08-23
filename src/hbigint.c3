// HBigInt, an arbitrary-precision BigInt box.
//
// A value is a two's-complement, little-endian vector of 32-bit limbs stored
// immediately after the header in the same allocation, so a small BigInt costs
// one limb rather than a fixed maximum. The vector is always normalized: the
// shortest form whose top limb still carries the correct sign. `len` is never
// zero, so `limbs()[0]` is always readable and `len == 1` means the value fits
// a single limb.
//
// Precision is bounded only by BIGINT_MAX_LIMBS, which exists so a runaway
// expression raises a RangeError instead of exhausting memory. Arithmetic never
// wraps or truncates silently.
//
// The box holds no references, making it a GC leaf. It sits on the heap's
// `heap_allocated` list like a buffer and is refcounted too, so a bigint held
// only by the constant pool survives on its refcount while runtime-produced
// ones are reclaimed by mark-and-sweep.
module boomkat::hbigint;

import boomkat::types;
import boomkat::heap;
import boomkat::bigmath;

alias Limb = bigmath::Limb;
const int LIMB_BITS = bigmath::LIMB_BITS;

// ============================================================================
// Limits
// ============================================================================

// Ceiling on a value's limb count: 2^26 limbs is ~2 billion bits, far past any
// legitimate computation, and keeps `len * LIMB_BITS` clear of int overflow.
const int BIGINT_MAX_LIMBS = 1 << 26;

faultdef BIGINT_OVERFLOW, BIGINT_DIV_ZERO, BIGINT_SYNTAX, BIGINT_ALLOC;

// ============================================================================
// HBigInt struct
// ============================================================================

// A boxed arbitrary-precision integer. The header is HeapHeader-compatible, so
// a raw cast to HeapHeader* reads the right htype and GC bits. The limbs follow
// the struct in the same allocation; see `limbs()`.
struct HBigInt {
    HeapHeader header;
    int        len;
}

// The limb vector, which lives immediately after the struct.
macro Limb* HBigInt.limbs(&self) => (Limb*)((char*)self + HBigInt::size);

// True when the value is negative, i.e. the sign bit of the top limb is set.
macro bool HBigInt.is_negative(&self) =>
    (self.limbs()[self.len - 1] >> (LIMB_BITS - 1)) != 0;

// True for zero, which normalizes to a single zero limb.
macro bool HBigInt.is_zero(&self) => self.len == 1 && self.limbs()[0] == 0;

// The all-ones or all-zeros limb that conceptually extends the value upward.
macro Limb HBigInt.sign_ext(&self) => self.is_negative() ? bigmath::LIMB_MAX : 0;

// ============================================================================
// Allocation
// ============================================================================

// Allocate an uninitialized HBigInt with room for `len` limbs. It starts at
// refcount 1 and is a temporary root, so a collection outside a safepoint
// cannot free it before a register or constant slot anchors it.
//
// The caller must fill every limb and then normalize (see `normalize`).
fn HBigInt*? hbigint_alloc_len(Heap* hp, int len) {
    if (len < 1 || len > BIGINT_MAX_LIMBS) return BIGINT_OVERFLOW~;
    usz bytes = HBigInt::size + (usz)len * Limb::size;
    void* raw = hp.alloc(bytes)!;
    HBigInt* b = (HBigInt*)raw;
    // init() zeroes the flags, sets refcount to 1, and links the header at the
    // head of heap_allocated.
    b.header.init(HType.BIGINT, &hp.heap_allocated);
    b.header.set_temproot();
    b.len = len;
    hp.live_obj_count++;
    if (hp.live_obj_count > hp.peak_live_obj_count) {
        hp.peak_live_obj_count = hp.live_obj_count;
    }
    return b;
}

// Trim redundant sign limbs in place. A limb is redundant when it merely
// repeats the sign and the limb below it already carries that sign, so the
// shortest form is reached by dropping from the top while that holds. `len`
// never falls below 1.
fn void HBigInt.normalize(&self) {
    Limb* t = self.limbs();
    while (self.len > 1) {
        Limb top = t[self.len - 1];
        Limb below_sign = t[self.len - 2] >> (LIMB_BITS - 1);
        // 0x00000000 above a non-negative limb, or 0xFFFFFFFF above a negative
        // one, adds nothing.
        if (top == 0 && below_sign == 0) { self.len--; continue; }
        if (top == bigmath::LIMB_MAX && below_sign == 1) { self.len--; continue; }
        break;
    }
}

// Allocate a BigInt holding a single signed limb-sized value.
fn HBigInt*? hbigint_from_slimb(Heap* hp, int v) {
    HBigInt* b = hbigint_alloc_len(hp, 1)!;
    b.limbs()[0] = (Limb)v;
    return b;
}

// Allocate a BigInt holding an int128. Kept because the VM, the constant pool
// and several builtins still speak int128 at their boundaries.
fn HBigInt*? hbigint_alloc(Heap* hp, int128 value) {
    // Four limbs always suffice for an int128, and normalize trims the rest.
    HBigInt* b = hbigint_alloc_len(hp, 4)!;
    Limb* t = b.limbs();
    uint128 u = (uint128)value;
    for (int i = 0; i < 4; i++) {
        t[i] = (Limb)(u >> (uint128)(i * LIMB_BITS));
    }
    b.normalize();
    return b;
}

// ============================================================================
// Arithmetic
//
// Each operation sizes its result for the widest possible outcome, computes it
// with the sign-extended inputs, then normalizes. Sign extension is what lets
// the unsigned limb kernels do signed arithmetic: reading past a value's top
// limb yields its sign limb, so operands of different widths line up.
// ============================================================================

// Limb `i` of `b`, extended with its sign beyond the stored vector.
macro Limb HBigInt.limb_at(&self, int i) =>
    i < self.len ? self.limbs()[i] : self.sign_ext();

// a + b, or a - b when `subtract`.
fn HBigInt*? hbigint_addsub(Heap* hp, HBigInt* a, HBigInt* b, bool subtract) {
    // One extra limb absorbs any carry out of the wider operand.
    int n = (a.len > b.len ? a.len : b.len) + 1;
    HBigInt* r = hbigint_alloc_len(hp, n)!;
    Limb* t = r.limbs();
    Limb carry = subtract ? 1 : 0;
    for (int i = 0; i < n; i++) {
        Limb bv = b.limb_at(i);
        if (subtract) bv = ~bv;   // two's complement: a - b == a + ~b + 1
        bigmath::DLimb v = (bigmath::DLimb)a.limb_at(i) + (bigmath::DLimb)bv
                         + (bigmath::DLimb)carry;
        t[i] = (Limb)v;
        carry = (Limb)(v >> LIMB_BITS);
    }
    r.normalize();
    return r;
}

// -a.
fn HBigInt*? hbigint_neg(Heap* hp, HBigInt* a) {
    int n = a.len + 1;
    HBigInt* r = hbigint_alloc_len(hp, n)!;
    Limb* t = r.limbs();
    Limb carry = 1;
    for (int i = 0; i < n; i++) {
        bigmath::DLimb v = (bigmath::DLimb)(~a.limb_at(i)) + (bigmath::DLimb)carry;
        t[i] = (Limb)v;
        carry = (Limb)(v >> LIMB_BITS);
    }
    r.normalize();
    return r;
}

// Copy `src`'s magnitude into `dst` as an unsigned limb vector of length `n`,
// negating if `src` is negative. Returns true when a negation happened, which
// the caller folds into the result's sign.
fn bool bigint_abs_into(Limb* dst, int n, HBigInt* src) {
    bool neg = src.is_negative();
    Limb carry = 1;
    for (int i = 0; i < n; i++) {
        Limb v = src.limb_at(i);
        if (neg) {
            bigmath::DLimb s = (bigmath::DLimb)(~v) + (bigmath::DLimb)carry;
            dst[i] = (Limb)s;
            carry = (Limb)(s >> LIMB_BITS);
        } else {
            dst[i] = v;
        }
    }
    return neg;
}

// a * b.
fn HBigInt*? hbigint_mul(Heap* hp, HBigInt* a, HBigInt* b) {
    if (a.is_zero() || b.is_zero()) return hbigint_from_slimb(hp, 0);
    int na = a.len;
    int nb = b.len;
    if (na + nb + 1 > BIGINT_MAX_LIMBS) return BIGINT_OVERFLOW~;

    // Work on magnitudes, then apply the sign. The product of two magnitudes
    // needs na+nb limbs, plus one so the top bit cannot be mistaken for a sign.
    Limb* ta = (Limb*)hp.alloc((usz)(na + nb) * Limb::size)!;
    defer hp.free((void*)ta);
    Limb* tb = (Limb*)hp.alloc((usz)nb * Limb::size)!;
    defer hp.free((void*)tb);

    bool nega = bigint_abs_into(ta, na, a);
    bool negb = bigint_abs_into(tb, nb, b);

    HBigInt* r = hbigint_alloc_len(hp, na + nb + 1)!;
    Limb* t = r.limbs();
    for (int i = 0; i < na + nb + 1; i++) t[i] = 0;
    bigmath::mp_mul_basecase(t, ta, na, tb, nb);

    if (nega != negb) {
        // Negate the magnitude in place to give the product its sign.
        Limb carry = 1;
        for (int i = 0; i < r.len; i++) {
            bigmath::DLimb v = (bigmath::DLimb)(~t[i]) + (bigmath::DLimb)carry;
            t[i] = (Limb)v;
            carry = (Limb)(v >> LIMB_BITS);
        }
    }
    r.normalize();
    return r;
}

// a / b and a % b. Division truncates toward zero and the remainder takes the
// dividend's sign, which is what ECMAScript requires (-17n / 3n is -5n, and
// -17n % 3n is -2n).
//
// `out_quot` and `out_rem` may each be null when that half is not wanted.
fn void? hbigint_divrem(Heap* hp, HBigInt* a, HBigInt* b,
                        HBigInt** out_quot, HBigInt** out_rem) {
    if (b.is_zero()) return BIGINT_DIV_ZERO~;

    int na = a.len;
    int nb = b.len;
    // Magnitudes, each one limb wider so a negated value cannot overflow into
    // its own sign bit.
    Limb* ma = (Limb*)hp.alloc((usz)(na + 1) * Limb::size)!;
    defer hp.free((void*)ma);
    Limb* mb = (Limb*)hp.alloc((usz)(nb + 1) * Limb::size)!;
    defer hp.free((void*)mb);

    bool nega = bigint_abs_into(ma, na + 1, a);
    bool negb = bigint_abs_into(mb, nb + 1, b);
    int la = na + 1;
    int lb = nb + 1;
    while (la > 1 && ma[la - 1] == 0) la--;
    while (lb > 1 && mb[lb - 1] == 0) lb--;

    if (la < lb) {
        // |a| < |b|: the quotient is zero and the remainder is a itself.
        if (out_quot != null) *out_quot = hbigint_from_slimb(hp, 0)!;
        if (out_rem != null) *out_rem = hbigint_copy(hp, a)!;
        return;
    }

    // Knuth D needs the divisor's top bit set, so shift both left by the
    // divisor's leading-zero count; the quotient is unaffected and the
    // remainder is shifted back afterwards.
    int shift = (int)$$clz(mb[lb - 1]);
    Limb* wa = (Limb*)hp.alloc((usz)(la + 2) * Limb::size)!;
    defer hp.free((void*)wa);
    Limb* wb = (Limb*)hp.alloc((usz)lb * Limb::size)!;
    defer hp.free((void*)wb);
    for (int i = 0; i < la + 2; i++) wa[i] = 0;
    wa[la] = bigmath::mp_shl(wa, ma, la, shift);
    bigmath::mp_shl(wb, mb, lb, shift);
    int wa_len = wa[la] != 0 ? la + 1 : la;
    if (wa_len == lb) { wa[wa_len] = 0; wa_len++; }   // mp_divnorm needs na > nb

    int nq = wa_len - lb + 1;
    Limb* q = (Limb*)hp.alloc((usz)nq * Limb::size)!;
    defer hp.free((void*)q);
    for (int i = 0; i < nq; i++) q[i] = 0;
    bigmath::mp_divnorm(q, wa, wa_len, wb, lb);

    if (out_quot != null) {
        HBigInt* qr = hbigint_alloc_len(hp, nq + 1)!;
        Limb* t = qr.limbs();
        for (int i = 0; i < nq; i++) t[i] = q[i];
        t[nq] = 0;
        if (nega != negb) hbigint_negate_limbs(t, qr.len);
        qr.normalize();
        *out_quot = qr;
    }
    if (out_rem != null) {
        // Undo the normalization shift to recover the true remainder.
        HBigInt* rr = hbigint_alloc_len(hp, lb + 1)!;
        Limb* t = rr.limbs();
        bigmath::mp_shr(t, wa, lb, shift, 0);
        t[lb] = 0;
        // The remainder takes the DIVIDEND's sign, per ECMAScript truncation.
        if (nega) hbigint_negate_limbs(t, rr.len);
        rr.normalize();
        *out_rem = rr;
    }
}

// Two's-complement negate a limb vector in place.
fn void hbigint_negate_limbs(Limb* t, int n) {
    Limb carry = 1;
    for (int i = 0; i < n; i++) {
        bigmath::DLimb v = (bigmath::DLimb)(~t[i]) + (bigmath::DLimb)carry;
        t[i] = (Limb)v;
        carry = (Limb)(v >> LIMB_BITS);
    }
}

// An independent copy of `src`.
fn HBigInt*? hbigint_copy(Heap* hp, HBigInt* src) {
    HBigInt* r = hbigint_alloc_len(hp, src.len)!;
    Limb* d = r.limbs();
    Limb* s = src.limbs();
    for (int i = 0; i < src.len; i++) d[i] = s[i];
    return r;
}

// ============================================================================
// Comparison
// ============================================================================

// -1, 0 or 1 as a is less than, equal to, or greater than b.
fn int hbigint_cmp(HBigInt* a, HBigInt* b) {
    bool na = a.is_negative();
    bool nb = b.is_negative();
    if (na != nb) return na ? -1 : 1;
    // Same sign: compare from the top of the wider vector down. Sign extension
    // makes the two comparable without materializing a common width.
    int n = a.len > b.len ? a.len : b.len;
    for (int i = n - 1; i >= 0; i--) {
        Limb av = a.limb_at(i);
        Limb bv = b.limb_at(i);
        if (av != bv) return av < bv ? -1 : 1;
    }
    return 0;
}

macro bool hbigint_eq(HBigInt* a, HBigInt* b) => hbigint_cmp(a, b) == 0;

// ============================================================================
// Shifts
// ============================================================================

// a << n, for n >= 0. Grows the value by n bits.
fn HBigInt*? hbigint_shl(Heap* hp, HBigInt* a, long n) {
    if (n == 0 || a.is_zero()) return hbigint_copy(hp, a);
    long limb_shift = n / LIMB_BITS;
    int bit_shift = (int)(n % LIMB_BITS);
    long total = (long)a.len + limb_shift + 1;
    if (total > BIGINT_MAX_LIMBS) return BIGINT_OVERFLOW~;

    HBigInt* r = hbigint_alloc_len(hp, (int)total)!;
    Limb* t = r.limbs();
    Limb* s = a.limbs();
    for (long i = 0; i < limb_shift; i++) t[i] = 0;
    // The extra top limb starts as the sign so a shifted negative stays negative.
    t[total - 1] = a.sign_ext();
    Limb carry = bigmath::mp_shl(t + limb_shift, s, a.len, bit_shift);
    if (bit_shift != 0) {
        t[limb_shift + a.len] = carry | (a.sign_ext() << bit_shift);
    } else {
        t[limb_shift + a.len] = a.sign_ext();
    }
    r.normalize();
    return r;
}

// a >> n, for n >= 0. Arithmetic shift: the sign is preserved, so a negative
// value floors toward negative infinity, which is what ECMAScript specifies.
fn HBigInt*? hbigint_shr(Heap* hp, HBigInt* a, long n) {
    if (n == 0 || a.is_zero()) return hbigint_copy(hp, a);
    long limb_shift = n / LIMB_BITS;
    int bit_shift = (int)(n % LIMB_BITS);
    if (limb_shift >= (long)a.len) {
        // Everything shifted out; the result is 0 or -1 by sign.
        return hbigint_from_slimb(hp, a.is_negative() ? -1 : 0);
    }
    int keep = a.len - (int)limb_shift;
    HBigInt* r = hbigint_alloc_len(hp, keep)!;
    Limb* t = r.limbs();
    Limb* s = a.limbs() + limb_shift;
    if (bit_shift == 0) {
        for (int i = 0; i < keep; i++) t[i] = s[i];
    } else {
        for (int i = 0; i < keep; i++) {
            Limb hi = (i + 1 < keep) ? s[i + 1] : a.sign_ext();
            t[i] = (s[i] >> bit_shift) | (hi << (LIMB_BITS - bit_shift));
        }
    }
    r.normalize();
    return r;
}

// ============================================================================
// Bitwise
//
// Two's-complement representation makes these limbwise once both operands are
// sign-extended to a common width, with no special casing for negatives.
// ============================================================================

enum BitOp : char { AND, OR, XOR }

fn HBigInt*? hbigint_bitop(Heap* hp, HBigInt* a, HBigInt* b, BitOp op) {
    int n = (a.len > b.len ? a.len : b.len);
    HBigInt* r = hbigint_alloc_len(hp, n)!;
    Limb* t = r.limbs();
    for (int i = 0; i < n; i++) {
        Limb av = a.limb_at(i);
        Limb bv = b.limb_at(i);
        switch (op) {
            case AND: t[i] = av & bv;
            case OR:  t[i] = av | bv;
            case XOR: t[i] = av ^ bv;
        }
    }
    r.normalize();
    return r;
}

// ~a, which in two's complement is -(a+1).
fn HBigInt*? hbigint_not(Heap* hp, HBigInt* a) {
    HBigInt* r = hbigint_alloc_len(hp, a.len)!;
    Limb* t = r.limbs();
    Limb* s = a.limbs();
    for (int i = 0; i < a.len; i++) t[i] = ~s[i];
    r.normalize();
    return r;
}

// ============================================================================
// String conversion
// ============================================================================

// Digits produced per limb-sized division step, and the divisor that yields
// them, for each radix 2..36. Dividing by the largest power of the radix that
// fits a limb converts a whole limb's worth of digits per pass instead of one
// digit at a time.
struct RadixStep { Limb divisor; int digits; }

fn RadixStep radix_step(uint radix) {
    Limb d = radix;
    int n = 1;
    // Grow while the next multiply still fits a limb.
    while ((bigmath::DLimb)d * (bigmath::DLimb)radix <= (bigmath::DLimb)bigmath::LIMB_MAX) {
        d *= radix;
        n++;
    }
    return { .divisor = d, .digits = n };
}

// Upper bound on the digit count of `b` in `radix`, plus room for a sign and
// a terminator. Uses 1 bit per digit as the floor, which never underestimates.
fn usz hbigint_string_cap(HBigInt* b, uint radix) {
    return (usz)b.len * LIMB_BITS + 2;
}

// Write `b` to `buf` in a radix from 2 to 36 and return the written slice.
// `buf` must hold at least hbigint_string_cap(b, radix) bytes.
fn char[]? hbigint_to_radix(Heap* hp, HBigInt* b, uint radix, char[] buf) {
    if (b.is_zero()) {
        buf[0] = '0';
        return buf[0:1];
    }
    bool neg = b.is_negative();

    // Work on the magnitude, destructively: each pass divides it down.
    int n = b.len + 1;
    Limb* m = (Limb*)hp.alloc((usz)n * Limb::size)!;
    defer hp.free((void*)m);
    bigint_abs_into(m, n, b);
    while (n > 1 && m[n - 1] == 0) n--;

    RadixStep step = radix_step(radix);
    usz pos = buf.len;
    while (!(n == 1 && m[0] == 0)) {
        Limb rem = bigmath::mp_div1(m, m, n, step.divisor, 0);
        while (n > 1 && m[n - 1] == 0) n--;
        bool last = (n == 1 && m[0] == 0);
        // Emit this chunk's digits low-to-high; pad all but the final chunk so
        // interior zeros are not lost.
        for (int k = 0; k < step.digits; k++) {
            if (last && rem == 0 && k > 0) break;
            Limb d = rem % radix;
            rem /= radix;
            buf[--pos] = d < 10 ? (char)('0' + (char)d) : (char)('a' + (char)(d - 10));
        }
    }
    if (neg) buf[--pos] = '-';

    usz len = buf.len - pos;
    for (usz i = 0; i < len; i++) buf[i] = buf[pos + i];
    return buf[0:len];
}

// ============================================================================
// Parsing
// ============================================================================

// Parse `digits` in `radix` into a new BigInt. The text must be non-empty and
// contain only valid digits for the radix; `_` separators are skipped.
fn HBigInt*? hbigint_parse_radix(Heap* hp, char[] s, uint radix) {
    // Each digit contributes at most log2(radix) bits; 6 covers radix 36, and
    // one extra limb keeps the top bit clear of the sign.
    long bits = (long)s.len * 6;
    long nl = bits / LIMB_BITS + 2;
    if (nl > BIGINT_MAX_LIMBS) return BIGINT_OVERFLOW~;

    HBigInt* r = hbigint_alloc_len(hp, (int)nl)!;
    Limb* t = r.limbs();
    for (int i = 0; i < r.len; i++) t[i] = 0;

    int used = 1;
    bool saw_digit = false;
    foreach (digit_ch : s) {
        if (digit_ch == '_') continue;
        uint d;
        if (digit_ch >= '0' && digit_ch <= '9') { d = (uint)(digit_ch - '0'); }
        else if (digit_ch >= 'a' && digit_ch <= 'z') { d = (uint)(digit_ch - 'a') + 10; }
        else if (digit_ch >= 'A' && digit_ch <= 'Z') { d = (uint)(digit_ch - 'A') + 10; }
        else { return BIGINT_SYNTAX~; }
        if (d >= radix) return BIGINT_SYNTAX~;
        saw_digit = true;
        // r = r * radix + d
        Limb carry = bigmath::mp_mul1(t, t, used, radix, d);
        if (carry != 0) {
            if (used + 1 > r.len) return BIGINT_OVERFLOW~;
            t[used] = carry;
            used++;
        }
    }
    if (!saw_digit) return BIGINT_SYNTAX~;
    r.normalize();
    return r;
}

// ============================================================================
// Exponentiation
// ============================================================================

// a ** e, for e >= 0. Square-and-multiply, so the cost is logarithmic in the
// exponent rather than linear.
fn HBigInt*? hbigint_pow(Heap* hp, HBigInt* a, HBigInt* e) {
    if (e.is_negative()) return BIGINT_SYNTAX~;   // caller raises the RangeError
    if (e.is_zero()) return hbigint_from_slimb(hp, 1);
    if (a.is_zero()) return hbigint_from_slimb(hp, 0);

    // An exponent past a limb would need more memory than any machine has;
    // the result's bit length is exponent * log2(|a|).
    if (e.len > 1) return BIGINT_OVERFLOW~;
    Limb exp = e.limbs()[0];

    HBigInt* result = hbigint_from_slimb(hp, 1)!;
    HBigInt* base = hbigint_copy(hp, a)!;
    while (exp != 0) {
        if ((exp & 1) != 0) result = hbigint_mul(hp, result, base)!;
        exp >>= 1;
        if (exp != 0) base = hbigint_mul(hp, base, base)!;
    }
    return result;
}

// ============================================================================
// BigInt.asIntN / BigInt.asUintN (ECMA-262 §21.2.2.1-2)
// ============================================================================

// a mod 2^bits, read as signed when `signed` and unsigned otherwise. Both are
// exact at any width now that values are unbounded, so neither can overflow.
fn HBigInt*? hbigint_as_n(Heap* hp, HBigInt* a, ulong bits, bool is_signed) {
    if (bits == 0) return hbigint_from_slimb(hp, 0);

    // Keep the low `bits` bits, plus one limb of headroom so an unsigned result
    // whose top bit is set does not read back as negative.
    long need = (long)(bits / (ulong)LIMB_BITS) + 2;
    if (need > BIGINT_MAX_LIMBS) return BIGINT_OVERFLOW~;

    HBigInt* r = hbigint_alloc_len(hp, (int)need)!;
    Limb* t = r.limbs();
    int full = (int)(bits / (ulong)LIMB_BITS);
    int rest = (int)(bits % (ulong)LIMB_BITS);
    for (int i = 0; i < r.len; i++) {
        if (i < full) {
            t[i] = a.limb_at(i);
        } else if (i == full && rest != 0) {
            t[i] = a.limb_at(i) & ((1u << rest) - 1);
        } else {
            t[i] = 0;
        }
    }
    if (is_signed) {
        // Sign-extend from bit `bits-1` downward, so the value reads as the
        // signed interpretation of that bit width.
        int sign_limb = (int)((bits - 1) / (ulong)LIMB_BITS);
        int sign_bit = (int)((bits - 1) % (ulong)LIMB_BITS);
        if ((t[sign_limb] >> sign_bit & 1) != 0) {
            // Set every bit at or above `bits`.
            if (rest != 0) t[full] |= ~((1u << rest) - 1);
            for (int i = (rest != 0 ? full + 1 : full); i < r.len; i++) {
                t[i] = bigmath::LIMB_MAX;
            }
        }
    }
    r.normalize();
    return r;
}

// ============================================================================
// TVal integration
// ============================================================================

// The box inside a BigInt TVal. Callers must have checked `is_bigint()`.
macro HBigInt* TVal.get_bigint(&self) => (HBigInt*)self.get_heapptr();

// ============================================================================
// Numeric conversion
// ============================================================================

// The value as a double, rounding when it exceeds 2^53. Infinite when the
// magnitude is past the double range, matching ECMAScript's Number(bigint).
fn double HBigInt.to_double(&self) {
    bool neg = self.is_negative();
    // Accumulate the exact magnitude first, then apply the sign. Complementing
    // limb-by-limb and adding one at the end would round before the correction
    // and lose the low bit for magnitudes past 2^53.
    int n = self.len;
    if (!neg) {
        double acc = 0.0;
        for (int i = n - 1; i >= 0; i--) {
            acc = acc * 4294967296.0 + (double)self.limbs()[i];
        }
        return acc;
    }
    // Negative: complement low-to-high so the carry propagates upward, scaling
    // each magnitude limb into place as it is produced.
    Limb carry = 1;
    double scale = 1.0;
    double total = 0.0;
    for (int i = 0; i < n; i++) {
        bigmath::DLimb t = (bigmath::DLimb)(~self.limbs()[i]) + (bigmath::DLimb)carry;
        carry = (Limb)(t >> LIMB_BITS);
        total += (double)(Limb)t * scale;
        scale *= 4294967296.0;
    }
    return -total;
}

// The value as an int128, saturating at the int128 bounds. Used only where an
// interface is fixed at 128 bits (typed arrays, DataView, Atomics).
fn int128 HBigInt.to_int128(&self) {
    int128 acc = 0;
    Limb ext = self.sign_ext();
    for (int i = 3; i >= 0; i--) {
        Limb v = i < self.len ? self.limbs()[i] : ext;
        acc = (acc << LIMB_BITS) | (int128)(uint128)v;
    }
    return acc;
}

// True when the value fits exactly in an int128.
fn bool HBigInt.fits_int128(&self) {
    if (self.len <= 4) return true;
    // Beyond four limbs every extra limb must be pure sign extension.
    Limb ext = self.sign_ext();
    for (int i = 4; i < self.len; i++) {
        if (self.limbs()[i] != ext) return false;
    }
    // The 128-bit window must also agree in sign with the value.
    return (self.limbs()[3] >> (LIMB_BITS - 1)) == (ext & 1);
}

// Decimal text for `b`, written into `buf` when it fits and into a heap
// allocation otherwise. `out_heap` receives the allocation to free, or null
// when `buf` was sufficient.
//
// Small values -- the overwhelming majority -- stay on the caller's stack; only
// a genuinely large BigInt pays for an allocation.
fn char[] hbigint_to_decimal(Heap* hp, HBigInt* b, char[] buf, char** out_heap) {
    *out_heap = null;
    usz need = hbigint_string_cap(b, 10);
    if (need <= buf.len) {
        char[]? s = hbigint_to_radix(hp, b, 10, buf);
        if (catch s) { buf[0] = '0'; return buf[0:1]; }
        return s;
    }
    void*? raw = hp.alloc(need);
    if (catch raw) { buf[0] = '0'; return buf[0:1]; }
    char* big = (char*)raw;
    *out_heap = big;
    char[] wide = big[0:need];
    char[]? s = hbigint_to_radix(hp, b, 10, wide);
    if (catch s) { big[0] = '0'; return wide[0:1]; }
    return s;
}

// True when the value is small enough to serve as a shift count without
// overflowing the bit arithmetic that consumes it.
fn bool HBigInt.fits_shift_count(&self) {
    if (self.len > 2) return false;
    // Two limbs still exceed any allocatable shift; cap at what a long can
    // express in bits without overflow.
    return self.len == 1 || (self.limbs()[1] == 0 || self.limbs()[1] == bigmath::LIMB_MAX);
}

// The magnitude of a shift count, as a non-negative long. Only meaningful when
// fits_shift_count() holds.
fn long HBigInt.to_shift_count(&self) {
    bool neg = self.is_negative();
    long v = (long)(ulong)self.limbs()[0];
    if (neg) {
        // Two's complement magnitude of a single-limb negative value.
        v = (long)(ulong)(~self.limbs()[0]) + 1;
    }
    return v;
}

// A BigInt equal to the integral double `v`, which must be finite. Used where
// a Number has to be compared or converted exactly (ES2020 §7.1.13 and the
// mixed BigInt/Number relational comparison).
fn HBigInt*? hbigint_from_double(Heap* hp, double v) {
    if (v != v) return BIGINT_SYNTAX~;
    if (v == 0.0) return hbigint_from_slimb(hp, 0);
    bool neg = v < 0.0;
    double m = neg ? -v : v;
    // Peel 32 bits at a time off the top by repeated scaling.
    int nl = 1;
    double probe = m;
    while (probe >= 4294967296.0) { probe /= 4294967296.0; nl++; }
    HBigInt* r = hbigint_alloc_len(hp, nl + 1)!;
    Limb* t = r.limbs();
    for (int i = 0; i < r.len; i++) t[i] = 0;
    for (int i = nl - 1; i >= 0; i--) {
        double scale = 1.0;
        for (int k = 0; k < i; k++) scale *= 4294967296.0;
        double q = m / scale;
        // Truncate toward zero; the residue carries into the lower limbs.
        Limb limb = (Limb)q;
        t[i] = limb;
        m -= (double)limb * scale;
    }
    if (neg) hbigint_negate_limbs(t, r.len);
    r.normalize();
    return r;
}

// Parse a BigInt literal's digit text. The lexer may hand this a `0x`, `0o` or
// `0b` prefix and `_` separators, both of which literals permit (unlike
// StringToBigInt). Literals are always non-negative: the `-` in `-5n` is a
// unary operator, not part of the literal.
fn HBigInt*? parse_bigint_literal(Heap* hp, char[] digits) {
    if (digits.len == 0) return BIGINT_SYNTAX~;
    uint radix = 10;
    usz i = 0;
    if (digits.len >= 2 && digits[0] == '0') {
        switch (digits[1]) {
            case 'x': case 'X': radix = 16; i = 2;
            case 'o': case 'O': radix = 8;  i = 2;
            case 'b': case 'B': radix = 2;  i = 2;
            default: break;
        }
    }
    if (i >= digits.len) return BIGINT_SYNTAX~;
    return hbigint_parse_radix(hp, digits[i..], radix);
}
