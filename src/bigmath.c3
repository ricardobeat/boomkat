// Arbitrary-precision integer arithmetic on 32-bit limbs.
//
// Values are two's-complement, little-endian limb vectors: `limbs[0]` is the
// least significant, and the top bit of the most significant limb is the sign.
// A value is always normalized -- the shortest representation whose sign bit
// still reads correctly -- so equality is a length check plus a memcmp, and
// `len == 1` covers everything that fits a single limb.
//
// The algorithms follow QuickJS-NG's bignum (MIT, Bellard/Gordon/Noordhuis/
// Ibarra Corretge), whose limb kernels are Knuth's classical algorithms. That
// implementation is validated against test262, and the division kernel here was
// checked limb-for-limb against it on randomized inputs before being adopted.
module boomkat::bigmath;

alias Limb = uint;
alias DLimb = ulong;      // double-width accumulator for mul/div
alias SLimb = int;
const int LIMB_BITS = 32;
const Limb LIMB_MAX = 0xFFFFFFFF;

// ============================================================================
// Limb-vector primitives
//
// Each takes explicit lengths and writes through a caller-owned destination, so
// they compose without allocating. `res` may alias `op1`.
// ============================================================================

// res = op1 + op2 + carry, over `n` limbs. Returns the carry out.
fn Limb mp_add(Limb* res, Limb* op1, Limb* op2, int n, Limb carry) {
    for (int i = 0; i < n; i++) {
        DLimb v = (DLimb)op1[i] + (DLimb)op2[i] + (DLimb)carry;
        res[i] = (Limb)v;
        carry = (Limb)(v >> LIMB_BITS);
    }
    return carry;
}

// res = op1 - op2 - borrow, over `n` limbs. Returns the borrow out.
fn Limb mp_sub(Limb* res, Limb* op1, Limb* op2, int n, Limb borrow) {
    for (int i = 0; i < n; i++) {
        DLimb v = (DLimb)op1[i] - (DLimb)op2[i] - (DLimb)borrow;
        res[i] = (Limb)v;
        borrow = (Limb)((v >> LIMB_BITS) & 1);
    }
    return borrow;
}

// tabr = taba * b + l, over `n` limbs. Returns the high limb.
fn Limb mp_mul1(Limb* tabr, Limb* taba, int n, Limb b, Limb l) {
    DLimb carry = (DLimb)l;
    for (int i = 0; i < n; i++) {
        DLimb t = (DLimb)taba[i] * (DLimb)b + carry;
        tabr[i] = (Limb)t;
        carry = t >> LIMB_BITS;
    }
    return (Limb)carry;
}

// tabr += taba * b, over `n` limbs. Returns the carry out.
fn Limb mp_add_mul1(Limb* tabr, Limb* taba, int n, Limb b) {
    DLimb carry = 0;
    for (int i = 0; i < n; i++) {
        DLimb t = (DLimb)taba[i] * (DLimb)b + (DLimb)tabr[i] + carry;
        tabr[i] = (Limb)t;
        carry = t >> LIMB_BITS;
    }
    return (Limb)carry;
}

// taba -= tabb * b, over `n` limbs. Returns the borrow out (as a carry to
// subtract from the next limb up).
fn Limb mp_sub_mul1(Limb* taba, Limb* tabb, int n, Limb b) {
    DLimb l = 0;
    for (int i = 0; i < n; i++) {
        DLimb t = (DLimb)tabb[i] * (DLimb)b + l;
        Limb low = (Limb)t;
        l = t >> LIMB_BITS;
        DLimb v = (DLimb)taba[i] - (DLimb)low;
        taba[i] = (Limb)v;
        // A borrow out of this limb is repaid by the next partial product.
        if (((v >> LIMB_BITS) & 1) != 0) l++;
    }
    return (Limb)l;
}

// Schoolbook multiply: tabr[0..na+nb) = taba[0..na) * tabb[0..nb).
// tabr must not alias either input.
fn void mp_mul_basecase(Limb* tabr, Limb* taba, int na, Limb* tabb, int nb) {
    tabr[na] = mp_mul1(tabr, taba, na, tabb[0], 0);
    for (int i = 1; i < nb; i++) {
        tabr[na + i] = mp_add_mul1(tabr + i, taba, na, tabb[i]);
    }
}

// Divide by a single limb, most significant first. Returns the remainder.
fn Limb mp_div1(Limb* tabr, Limb* taba, int n, Limb b, Limb r) {
    for (int i = n - 1; i >= 0; i--) {
        DLimb a1 = ((DLimb)r << LIMB_BITS) | (DLimb)taba[i];
        tabr[i] = (Limb)(a1 / (DLimb)b);
        r = (Limb)(a1 % (DLimb)b);
    }
    return r;
}

// Knuth Algorithm D. Divides taba[0..na) by tabb[0..nb), writing the quotient
// to tabq[0..na-nb] and leaving the remainder in taba[0..nb).
//
// Requires the divisor to be normalized (top bit of tabb[nb-1] set) and
// na > nb; callers go through bigint_divrem, which arranges both.
fn void mp_divnorm(Limb* tabq, Limb* taba, int na, Limb* tabb, int nb) {
    Limb b1 = tabb[nb - 1];
    if (nb == 1) {
        taba[0] = mp_div1(tabq, taba, na, b1, 0);
        return;
    }
    int n = na - nb;

    // First iteration is special: the quotient limb can only be 0 or 1.
    Limb q = 1;
    for (int j = nb - 1; j >= 0; j--) {
        if (taba[n + j] != tabb[j]) {
            if (taba[n + j] < tabb[j]) q = 0;
            break;
        }
    }
    tabq[n] = q;
    if (q != 0) mp_sub(taba + n, taba + n, tabb, nb, 0);

    for (int i = n - 1; i >= 0; i--) {
        // Estimate the quotient limb from the top two limbs of the remainder.
        // The estimate is at most 2 too large, which the correction loop fixes.
        if (taba[i + nb] >= b1) {
            q = LIMB_MAX;
        } else {
            DLimb al = ((DLimb)taba[i + nb] << LIMB_BITS) | (DLimb)taba[i + nb - 1];
            q = (Limb)(al / (DLimb)b1);
        }
        Limb r = mp_sub_mul1(taba + i, tabb, nb, q);
        Limb v = taba[i + nb];
        Limb a = v - r;
        bool overshot = a > v;   // unsigned wrap means the estimate was too big
        taba[i + nb] = a;
        if (overshot) {
            // Add the divisor back until the remainder is non-negative again.
            while (true) {
                q--;
                Limb carry = mp_add(taba + i, taba + i, tabb, nb, 0);
                taba[i + nb] += carry;
                if (carry != 0) break;
            }
        }
        tabq[i] = q;
    }
}

// Shift left by 0..31 bits within a limb vector. Returns the bits shifted out.
fn Limb mp_shl(Limb* tabr, Limb* taba, int n, int shift) {
    if (shift == 0) {
        for (int i = 0; i < n; i++) tabr[i] = taba[i];
        return 0;
    }
    Limb carry = 0;
    for (int i = 0; i < n; i++) {
        Limb v = taba[i];
        tabr[i] = (v << shift) | carry;
        carry = v >> (LIMB_BITS - shift);
    }
    return carry;
}

// Shift right by 0..31 bits, feeding `high` into the top. Returns bits shifted out.
fn Limb mp_shr(Limb* tabr, Limb* taba, int n, int shift, Limb high) {
    if (shift == 0) {
        for (int i = 0; i < n; i++) tabr[i] = taba[i];
        return 0;
    }
    Limb low = 0;
    for (int i = n - 1; i >= 0; i--) {
        Limb v = taba[i];
        tabr[i] = (v >> shift) | (high << (LIMB_BITS - shift));
        high = v;
        low = v;
    }
    return low << (LIMB_BITS - shift);
}
