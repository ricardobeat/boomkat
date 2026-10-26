// Arbitrary-precision integer arithmetic on 32-bit limbs.
//
// Values are two's-complement, little-endian limb vectors: `limbs[0]` is the
// least significant, and the top bit of the most significant limb is the sign.
// Values are always normalized to the shortest representation whose sign bit
// still reads correctly, so equality is a length check plus a memcmp.
//
// The limb primitives are the classical algorithms of Knuth, TAOCP vol. 2,
// section 4.3.1: carry-propagating addition and subtraction, schoolbook
// multiplication, short division by one limb, and long division (Algorithm D).
module boomkat::lib::bigmath;

alias Limb = uint;
alias DLimb = ulong;      // double-width accumulator for mul/div
alias SLimb = int;
const int LIMB_BITS = 32;
const Limb LIMB_MAX = 0xFFFFFFFF;

// ============================================================================
// Limb-vector primitives
//
// Each takes explicit lengths and writes to a caller-owned destination. `res`
// may alias `op1`.
// ============================================================================

// res = op1 + op2 + carry, over `n` limbs, least significant first. Returns
// the carry out of the top limb. With carry in {0, 1}, the sum of three limbs
// fits the double-width accumulator with at most one bit to spare.
fn Limb mp_add(Limb* res, Limb* op1, Limb* op2, int n, Limb carry) {
    DLimb acc = (DLimb)carry;
    for (int i = 0; i < n; i++) {
        acc += (DLimb)op1[i] + (DLimb)op2[i];
        res[i] = (Limb)acc;
        acc >>= LIMB_BITS;
    }
    return (Limb)acc;
}

// res = op1 - op2 - borrow, over `n` limbs, least significant first. Returns
// the borrow out of the top limb (0 or 1). The difference is formed modulo
// B^2; when it goes negative, bit LIMB_BITS of the wrapped value is set.
fn Limb mp_sub(Limb* res, Limb* op1, Limb* op2, int n, Limb borrow) {
    for (int i = 0; i < n; i++) {
        DLimb diff = (DLimb)op1[i] - (DLimb)op2[i] - (DLimb)borrow;
        res[i] = (Limb)diff;
        borrow = (Limb)(diff >> LIMB_BITS) & 1;
    }
    return borrow;
}

// dst = src * m + addend, over `len` limbs. Returns the limb that spills past
// the top. `dst` may alias `src`.
fn Limb mp_mul1(Limb* dst, Limb* src, int len, Limb m, Limb addend) {
    DLimb acc = (DLimb)addend;
    for (int i = 0; i < len; i++) {
        acc += (DLimb)src[i] * (DLimb)m;
        dst[i] = (Limb)acc;
        acc >>= LIMB_BITS;
    }
    return (Limb)acc;
}

// dst += src * m, over `len` limbs. Returns the limb that spills past the top.
// The accumulator cannot overflow: (B-1)^2 + 2(B-1) is exactly B^2 - 1.
fn Limb mp_add_mul1(Limb* dst, Limb* src, int len, Limb m) {
    DLimb acc = 0;
    for (int i = 0; i < len; i++) {
        acc += (DLimb)src[i] * (DLimb)m + (DLimb)dst[i];
        dst[i] = (Limb)acc;
        acc >>= LIMB_BITS;
    }
    return (Limb)acc;
}

// dst -= src * m, over `len` limbs. Returns the amount still owed by the limb
// above `dst[len-1]`.
fn Limb mp_sub_mul1(Limb* dst, Limb* src, int len, Limb m) {
    DLimb owed = 0;
    for (int i = 0; i < len; i++) {
        DLimb p = (DLimb)src[i] * (DLimb)m + owed;
        Limb lo = (Limb)p;
        // The high half of p is at most B-2, so taking one more cannot wrap.
        owed = (p >> LIMB_BITS) + (dst[i] < lo ? (DLimb)1 : (DLimb)0);
        dst[i] -= lo;
    }
    return (Limb)owed;
}

// Schoolbook product: out[0..na+nb) = a[0..na) * b[0..nb), accumulated one
// row of `a * b[j]` at a time. `out` must not alias either input.
fn void mp_mul_basecase(Limb* out, Limb* a, int na, Limb* b, int nb) {
    for (int i = 0; i < na; i++) out[i] = 0;
    for (int j = 0; j < nb; j++) {
        out[na + j] = mp_add_mul1(out + j, a, na, b[j]);
    }
}

// Short division: tabr[0..n) = (r * B^n + taba[0..n)) / b, working from the
// most significant limb down. Returns the final remainder. Requires b != 0 and
// r < b, so each partial quotient fits one limb. `tabr` may alias `taba`.
fn Limb mp_div1(Limb* tabr, Limb* taba, int n, Limb b, Limb r) {
    DLimb divisor = (DLimb)b;
    for (int i = n - 1; i >= 0; i--) {
        DLimb num = ((DLimb)r << LIMB_BITS) | (DLimb)taba[i];
        tabr[i] = (Limb)(num / divisor);
        r = (Limb)(num % divisor);
    }
    return r;
}

// Long division, Knuth TAOCP vol. 2, section 4.3.1, Algorithm D. Divides
// u[0..nu) by v[0..nv), writing the quotient to q[0..nu-nv] and leaving the
// remainder in u[0..nv); the limbs of u above that end up zero.
//
// Requires v normalized (top bit of v[nv-1] set) and nu > nv; bigint_divrem
// arranges both. The limb u[nu] of Knuth's formulation is never stored: the
// first step reads it as zero.
fn void mp_divnorm(Limb* q, Limb* u, int nu, Limb* v, int nv) {
    Limb v1 = v[nv - 1];
    if (nv == 1) {
        u[0] = mp_div1(q, u, nu, v1, 0);
        return;
    }
    Limb v2 = v[nv - 2];
    DLimb base = (DLimb)1 << LIMB_BITS;

    for (int j = nu - nv; j >= 0; j--) {
        // The current window is u[j..j+nv], with its top limb implicit at j = nu-nv.
        bool top_stored = j + nv < nu;
        Limb top = top_stored ? u[j + nv] : 0;

        // D3: estimate the digit from the window's top two limbs, then refine
        // it with v2. Afterwards it is exact or one too large.
        DLimb num = ((DLimb)top << LIMB_BITS) | (DLimb)u[j + nv - 1];
        DLimb qhat = num / (DLimb)v1;
        DLimb rhat = num % (DLimb)v1;
        while (qhat >= base || qhat * (DLimb)v2 > ((rhat << LIMB_BITS) | (DLimb)u[j + nv - 2])) {
            qhat--;
            rhat += (DLimb)v1;
            if (rhat >= base) break;
        }

        // D4: subtract qhat * v from the window.
        Limb owed = mp_sub_mul1(u + j, v, nv, (Limb)qhat);
        bool negative = owed > top;
        if (top_stored) u[j + nv] = top - owed;

        // D6: the estimate was one too large, so add v back once.
        if (negative) {
            qhat--;
            Limb carry = mp_add(u + j, u + j, v, nv, 0);
            if (top_stored) u[j + nv] += carry;
        }
        q[j] = (Limb)qhat;
    }
}

// tabr[0..n) = taba[0..n) << shift, for shift in 0..LIMB_BITS-1. Returns the
// bits pushed out of the top limb, right-aligned. `tabr` may alias `taba`.
// A zero shift is a copy; it is handled apart because a shift by the full
// limb width is undefined.
fn Limb mp_shl(Limb* tabr, Limb* taba, int n, int shift) {
    if (shift == 0) {
        for (int i = 0; i < n; i++) tabr[i] = taba[i];
        return 0;
    }
    int back = LIMB_BITS - shift;
    Limb spill = 0;
    for (int i = 0; i < n; i++) {
        Limb limb = taba[i];
        tabr[i] = (limb << shift) | spill;
        spill = limb >> back;
    }
    return spill;
}

// tabr[0..n) = taba[0..n) >> shift, for shift in 0..LIMB_BITS-1, with the low
// `shift` bits of `fill` entering at the top. Returns the bits dropped off the
// bottom limb, left-aligned. `tabr` may alias `taba`. A zero shift is a copy.
fn Limb mp_shr(Limb* tabr, Limb* taba, int n, int shift, Limb fill) {
    if (shift == 0) {
        for (int i = 0; i < n; i++) tabr[i] = taba[i];
        return 0;
    }
    if (n <= 0) return 0;
    int back = LIMB_BITS - shift;
    Limb above = fill;
    for (int i = n - 1; i >= 0; i--) {
        Limb limb = taba[i];
        tabr[i] = (limb >> shift) | (above << back);
        above = limb;
    }
    return above << back;
}
