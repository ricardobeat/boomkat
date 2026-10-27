function eq(a, b) { if (!Object.is(a, b)) throw Error(a + ' != ' + b); }
function runtime(a, b, op) {
    if (op === 0) return a & b;
    if (op === 1) return a | b;
    if (op === 2) return a ^ b;
    if (op === 3) return a << b;
    if (op === 4) return a >> b;
    return a >>> b;
}
eq(4294967297 & 3, runtime(4294967297, 3, 0));
eq(-3.75 | 0, runtime(-3.75, 0, 1));
eq(4294967295 ^ 2147483648, runtime(4294967295, 2147483648, 2));
eq(1 << 31, runtime(1, 31, 3));
eq(-2147483648 >> 33, runtime(-2147483648, 33, 4));
eq(-1 >>> 0, 4294967295);
eq(1 << -1, runtime(1, -1, 3));
eq((0 / 0) | 0, 0);
eq((1 / 0) >>> 0, 0);
eq(~4294967296, -1);
eq(~-0, -1);
eq(((1 << 16) - 1) & 255, 255);
print('constant bit folding: PASS');
