// No BigInt value can enter through literals, constructors or typed arrays.
// Optional allocation/conversion calls fail; value-only calls enforce that invariant.
module boomkat::hbigint @feat(NO_BIGINT);

import boomkat::types;
import boomkat::heap;

faultdef BIGINT_DISABLED;

fn HBigInt*? hbigint_alloc_len(Heap* hp, int len) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_from_slimb(Heap* hp, int v) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_alloc(Heap* hp, int128 value) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_addsub(Heap* hp, HBigInt* a, HBigInt* b, bool subtract) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_neg(Heap* hp, HBigInt* a) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_mul(Heap* hp, HBigInt* a, HBigInt* b) { return BIGINT_DISABLED~; }

fn void? hbigint_divrem(Heap* hp, HBigInt* a, HBigInt* b,
                        HBigInt** out_quot, HBigInt** out_rem) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_copy(Heap* hp, HBigInt* src) { return BIGINT_DISABLED~; }

fn int hbigint_cmp(HBigInt* a, HBigInt* b) { unreachable("BigInt value in a build without BigInt"); }

fn HBigInt*? hbigint_shl(Heap* hp, HBigInt* a, long n) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_shr(Heap* hp, HBigInt* a, long n) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_bitop(Heap* hp, HBigInt* a, HBigInt* b, BitOp op) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_not(Heap* hp, HBigInt* a) { return BIGINT_DISABLED~; }

fn usz hbigint_string_cap(HBigInt* b, uint radix) { unreachable("BigInt value in a build without BigInt"); }

fn char[]? hbigint_to_radix(Heap* hp, HBigInt* b, uint radix, char[] buf) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_parse_radix(Heap* hp, char[] s, uint radix) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_pow(Heap* hp, HBigInt* a, HBigInt* e) { return BIGINT_DISABLED~; }

fn HBigInt*? hbigint_as_n(Heap* hp, HBigInt* a, ulong bits, bool is_signed) { return BIGINT_DISABLED~; }

fn double HBigInt.to_double(&self) { unreachable("BigInt value in a build without BigInt"); }

fn int128 HBigInt.to_int128(&self) { unreachable("BigInt value in a build without BigInt"); }

fn bool HBigInt.fits_int128(&self) { unreachable("BigInt value in a build without BigInt"); }

fn char[] hbigint_to_decimal(Heap* hp, HBigInt* b, char[] buf, char** out_heap) { unreachable("BigInt value in a build without BigInt"); }

fn bool HBigInt.fits_shift_count(&self) { unreachable("BigInt value in a build without BigInt"); }

fn long HBigInt.to_shift_count(&self) { unreachable("BigInt value in a build without BigInt"); }

fn HBigInt*? hbigint_from_double(Heap* hp, double v) { return BIGINT_DISABLED~; }

fn HBigInt*? parse_bigint_literal(Heap* hp, char[] digits) { return BIGINT_DISABLED~; }
