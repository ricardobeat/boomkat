// A binary operator whose two operands are both objects runs ToPrimitive on
// each. The first result lives only in the VM's call-result slot, which the
// second ToPrimitive call replaces: the operator must retain the first
// primitive across that call or it reads a freed string.
var fail = 0;
var check = function (name, got, want) {
  if (got !== want) { fail++; print("FAIL " + name + ": " + got + " !== " + want); }
};

// Fresh, non-interned strings from each side: join allocates a new string.
var left = { valueOf: function () { return ["abcdefghijklmnop", "q"].join(); } };
var right = { valueOf: function () { return ["zyxwvutsrqponmlk", "j"].join(); } };
var expect = ["abcdefghijklmnop", "q"].join() + ["zyxwvutsrqponmlk", "j"].join();
for (var i = 0; i < 20000; i++) {
  check("add", left + right, expect);
}

// Relational comparison: both primitives are strings compared by units.
var lo = { valueOf: function () { return ["aaaaaaaaaaaaaaaa", "a"].join(); } };
var hi = { valueOf: function () { return ["bbbbbbbbbbbbbbbb", "b"].join(); } };
for (var j = 0; j < 20000; j++) {
  check("lt", lo < hi, true);
  check("gt", lo > hi, false);
}

// A compiled callee's result lives in the same slot as a builtin's.
var mk = function (s) { return { valueOf: function () { return s + j; } }; };
var a = mk("first-string-value-"), b = mk("second-string-value-");
for (var k = 0; k < 2000; k++) {
  check("add-js", a + b, "first-string-value-" + j + "second-string-value-" + j);
}

// BigInt operands reach their arithmetic through the same two conversions.
var big1 = { valueOf: function () { return 10n ** 30n; } };
var big2 = { valueOf: function () { return 10n ** 20n; } };
for (var m = 0; m < 2000; m++) {
  check("bigint-add", big1 + big2, 10n ** 30n + 10n ** 20n);
}

if (fail === 0) print("PASS");
