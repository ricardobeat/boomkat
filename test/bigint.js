"use strict";
// Plan 056 — BigInt Phase 1 + 2 acceptance tests.

var passed = 0;
var failed = 0;
function ok(cond, label) {
    if (cond) { passed++; }
    else { failed++; console.log("FAIL: " + label); }
}
function throws(fn, ctor, label) {
    try { fn(); failed++; console.log("FAIL (no throw): " + label); }
    catch (e) {
        if (ctor && e.constructor.name !== ctor) {
            failed++; console.log("FAIL (wrong error " + e.constructor.name + "): " + label);
        } else { passed++; }
    }
}

// --- literals & typeof ---
ok(typeof 0n === "bigint", "typeof 0n");
ok(typeof 9007199254740993n === "bigint", "typeof big literal");
ok(0xFFn === 255n, "hex literal");
ok(0b1010n === 10n, "binary literal");
ok(0o77n === 63n, "octal literal");
ok(1_000n === 1000n, "separator literal");

// --- arithmetic ---
ok(10n + 20n === 30n, "add");
ok(100n * 3n === 300n, "mul");
ok(7n / 2n === 3n, "div trunc");
ok(7n % 2n === 1n, "rem");
ok(2n ** 10n === 1024n, "pow");
ok(-5n === (0n - 5n), "unary minus");
ok(~5n === -6n, "bitwise not");
ok((5n & 3n) === 1n, "bit and");
ok((5n | 2n) === 7n, "bit or");
ok((5n ^ 1n) === 4n, "bit xor");
ok((1n << 10n) === 1024n, "left shift");
ok((1024n >> 2n) === 256n, "right shift");

// --- inc/dec ---
var xi = 5n; xi++; ok(xi === 6n, "postfix ++");
var xj = 5n; ++xj; ok(xj === 6n, "prefix ++");
var xk = 5n; xk--; ok(xk === 4n, "postfix --");
var sumLoop = 0n;
for (var li = 0n; li < 5n; li++) { sumLoop += li; }
ok(sumLoop === 10n, "for loop over bigint");

// --- comparisons ---
ok(1n == 1, "1n == 1");
ok(!(1n === 1), "1n !== 1");
ok(1n < 2, "1n < 2 (number)");
ok(2n > 1n, "2n > 1n");
ok(1n <= 1n, "1n <= 1n");
ok(3n >= 2, "3n >= 2 (number)");
ok(2n == "2", "2n == '2'");
ok(!(2n === "2"), "2n !== '2'");

// --- mixed-type errors ---
throws(function () { return 1n + 1; }, "TypeError", "1n + 1 throws");
throws(function () { return 1n - 1; }, "TypeError", "1n - 1 throws");
throws(function () { return +5n; }, "TypeError", "unary +5n throws");
throws(function () { return 1n >>> 1n; }, "TypeError", "unsigned shift throws");

// --- div/mod by zero + overflow ---
throws(function () { return 1n / 0n; }, "RangeError", "1n / 0n throws");
throws(function () { return 1n % 0n; }, "RangeError", "1n % 0n throws");

// --- constructor ---
ok(BigInt(42) === 42n, "BigInt(42)");
ok(BigInt("0x10") === 16n, "BigInt('0x10')");
ok(BigInt("100") === 100n, "BigInt('100')");
ok(BigInt(true) === 1n, "BigInt(true)");
ok(BigInt(false) === 0n, "BigInt(false)");
throws(function () { return BigInt(1.5); }, "RangeError", "BigInt(1.5) throws");
throws(function () { return BigInt("xyz"); }, "SyntaxError", "BigInt('xyz') throws");
throws(function () { return new BigInt(1); }, "TypeError", "new BigInt throws");

// --- asIntN / asUintN ---
ok(BigInt.asIntN(8, 257n) === 1n, "asIntN(8,257n)");
ok(BigInt.asUintN(8, -1n) === 255n, "asUintN(8,-1n)");
ok(BigInt.asIntN(8, 128n) === -128n, "asIntN(8,128n)");
ok(BigInt.asUintN(4, 17n) === 1n, "asUintN(4,17n)");
ok(BigInt.asIntN(0, 5n) === 0n, "asIntN(0,x)");

// --- toString / valueOf ---
ok((255n).toString(16) === "ff", "toString(16)");
ok((255n).toString() === "255", "toString()");
ok((10n).toString(2) === "1010", "toString(2)");
ok((-255n).toString(16) === "-ff", "negative toString(16)");
ok((5n).valueOf() === 5n, "valueOf");

// --- ToString / interpolation ---
ok(`${42n}` === "42", "template interpolation");
ok(String(255n) === "255", "String(bigint)");
ok("v=" + 10n === "v=10", "string concat");
ok(Object.prototype.toString.call(5n) === "[object BigInt]", "toStringTag");

// --- arbitrary precision: values far past 64 and 128 bits are exact ---
var P127 = -1n << 127n;
// Shifting right by a huge NEGATIVE count is a huge left shift, which cannot
// be allocated and must raise RangeError rather than silently saturating.
throws(function () { return 5n >> P127; }, "RangeError", "5n >> (-2^127) is an unallocatable left shift");
ok(-3n << P127 === -1n, "-3n << P127 saturates to -1n");
ok(5n >> 100n === 0n, "large right shift saturates to 0n");
ok(-1n >> 200n === -1n, "large right shift of -1n saturates to -1n");
ok(~P127 === 170141183460469231731687303715884105727n, "~(-2^127) == 2^127-1");
ok(-P127 === 170141183460469231731687303715884105728n, "-(-2^127) == 2^127");
ok(P127 / -1n === 170141183460469231731687303715884105728n, "(-2^127) / -1n == 2^127");
ok(P127 % -1n === 0n, "(-2^127) % -1n == 0n");
ok(P127 >> 1n === -(2n ** 126n), "(-2^127) >> 1n == -2^126");

// Past the old 128-bit ceiling entirely.
ok(2n ** 128n === 340282366920938463463374607431768211456n, "2^128 exact");
ok(2n ** 256n === 115792089237316195423570985008687907853269984665640564039457584007913129639936n, "2^256 exact");
ok((2n ** 64n) * (2n ** 64n) === 2n ** 128n, "128-bit product exact");
ok(1n << 200n === 2n ** 200n, "shift past 128 bits");
ok((2n ** 200n) >> 200n === 1n, "shift back down is lossless");

// Division and remainder truncate toward zero at any width.
var BIG = 2n ** 300n + 12345n;
ok(BIG / 1000n * 1000n + BIG % 1000n === BIG, "divmod identity at 300 bits");
ok(-BIG / 1000n === -(BIG / 1000n), "division truncates toward zero");
ok(-BIG % 1000n === -(BIG % 1000n), "remainder takes the dividend's sign");

// Decimal round-trip of a large literal.
var HUGE = 123456789012345678901234567890123456789012345678901234567890n;
ok(String(HUGE) === "123456789012345678901234567890123456789012345678901234567890", "large decimal round-trip");
ok(BigInt(String(HUGE)) === HUGE, "String -> BigInt round-trip");
ok((2n ** 200n).toString(16) === "100000000000000000000000000000000000000000000000000", "hex of 2^200");

// asIntN / asUintN are exact at widths past 128 bits.
ok(BigInt.asUintN(64, -1n) === 18446744073709551615n, "asUintN(64, -1n)");
ok(BigInt.asIntN(64, 2n ** 63n) === -9223372036854775808n, "asIntN(64, 2^63)");
ok(BigInt.asUintN(200, -1n) === 2n ** 200n - 1n, "asUintN(200, -1n)");
ok(BigInt.asIntN(129, 2n ** 128n) === -(2n ** 128n), "asIntN(129, 2^128)");

console.log("passed=" + passed + " failed=" + failed);
