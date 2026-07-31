// Bitwise operations
// Demonstrates & | ^ ~ << >> >>> on integers.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// AND, OR, XOR, NOT
assert((0xFF & 0x0F) === 0x0F, "AND");
assert((0xF0 | 0x0F) === 0xFF, "OR");
assert((0xFF ^ 0x0F) === 0xF0, "XOR");
assert((~0) === -1, "NOT 0");
assert((~0xFF) === -256, "NOT 0xFF");

// Shifts
assert((1 << 4) === 16, "<<4");
assert((256 >> 4) === 16, ">>4");
assert((-1 >>> 4) === 0x0FFFFFFF, ">>>4");

// Useful idioms
function isOdd(n) { return (n & 1) === 1; }
function isPowerOfTwo(n) { return n > 0 && (n & (n - 1)) === 0; }

assert(isOdd(3) === true, "isOdd(3)");
assert(isOdd(4) === false, "isOdd(4)");
assert(isPowerOfTwo(8) === true, "pow2(8)");
assert(isPowerOfTwo(6) === false, "pow2(6)");

print("engine/bitwise: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");