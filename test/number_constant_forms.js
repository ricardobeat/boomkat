// Integral literals outside the LDINT range load as fastints; -0 and
// fractions stay doubles.
function check(a, b, msg) { if (!Object.is(a, b)) throw new Error(msg + ": " + a + " vs " + b); }
var big = 0xffff;
check(70000 & big, 4464, "and");
check(1 / -0, -Infinity, "neg zero");
check(1 / (0 * -70000), -Infinity, "neg zero product");
check(Object.is(-0, 0), false, "-0 is not 0");
check(140737488355327 + 1, 140737488355328, "fastint max");
check(2147483648 | 0, -2147483648, "or");
check(typeof 100000, "number", "typeof");
check(String(1e21), "1e+21", "string 1e21");
check(String(123456789), "123456789", "string int");
var o = { 100000: "a", 1e5: "b", 0x186a0: "c" };
check(o[100000], "c", "numeric key");
class C { 100000() { return 1; } static 200000() { return 2; } }
check(new C()[100000](), 1, "class method key");
check(C[200000](), 2, "static method key");
check(Object.keys(o).join(), "100000", "keys");
