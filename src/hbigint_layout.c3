// BigInt layout stays available to shared value and GC code.
module boomkat::hbigint;

import boomkat::types;
import boomkat::heap;
import boomkat::lib::bigmath;

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

macro Limb* HBigInt.limbs(&self) => (Limb*)((char*)self + HBigInt::size);

macro bool HBigInt.is_negative(&self) =>
    (self.limbs()[self.len - 1] >> (LIMB_BITS - 1)) != 0;

macro bool HBigInt.is_zero(&self) => self.len == 1 && self.limbs()[0] == 0;

macro Limb HBigInt.sign_ext(&self) => self.is_negative() ? bigmath::LIMB_MAX : 0;

macro Limb HBigInt.limb_at(&self, int i) =>
    i < self.len ? self.limbs()[i] : self.sign_ext();

macro bool hbigint_eq(HBigInt* a, HBigInt* b) => hbigint_cmp(a, b) == 0;

macro HBigInt* TVal.get_bigint(&self) => (HBigInt*)self.get_heapptr();

enum BitOp : char { AND, OR, XOR }
struct RadixStep { Limb divisor; int digits; }
