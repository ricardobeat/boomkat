// ECMA-262 ApplyStringOrNumericBinaryOperator applies ToNumeric to both
// operands before choosing the BigInt or Number operation, so an object whose
// valueOf yields a BigInt takes the BigInt path everywhere, and the unary and
// update operators follow ToNumeric the same way.
var fail = 0;
var check = function (name, got, want) {
  if (got !== want) { fail++; print("FAIL " + name + ": " + String(got) + " !== " + String(want)); }
};
var throws = function (name, fn, ctor) {
  try { fn(); } catch (e) {
    if (e instanceof ctor) return;
    fail++; print("FAIL " + name + ": threw " + e);
    return;
  }
  fail++; print("FAIL " + name + ": did not throw");
};
var big = function (n) { return { valueOf: function () { return n; } }; };

check("sub", big(3n) - big(1n), 2n);
check("sub-left-obj", big(3n) - 1n, 2n);
check("sub-right-obj", 3n - big(1n), 2n);
check("mul", big(3n) * big(4n), 12n);
check("div", big(7n) / big(2n), 3n);
check("mod", big(7n) % big(2n), 1n);
check("exp", big(2n) ** big(10n), 1024n);
check("shl", big(1n) << big(4n), 16n);
check("shr", big(-16n) >> big(2n), -4n);
check("band", big(6n) & big(3n), 2n);
check("bor", big(6n) | big(3n), 7n);
check("bxor", big(6n) ^ big(3n), 5n);
check("add", big(1n) + big(2n), 3n);
check("lt", big(1n) < big(2n), true);
check("unm", -big(5n), -5n);
check("bnot", ~big(5n), -6n);
check("mul-imm", big(5n) * 2n, 10n);
check("shl-imm", big(1n) << 3n, 8n);

var x = big(5n);
x++;
check("inc", x, 6n);
x = big(5n);
x--;
check("dec", x, 4n);
x = big(5n);
check("postinc-value", x++, 5n);
check("postinc", x, 6n);
x = big(5n);
check("preinc", ++x, 6n);
x = big(5n);
x += big(2n);
check("add-assign", x, 7n);
x = big(5n);
x -= 2n;
check("sub-assign", x, 3n);
var o = { n: big(5n) };
o.n++;
check("inc-prop", o.n, 6n);
o.n = big(5n);
o.n -= big(2n);
check("sub-assign-prop", o.n, 3n);

// Number results stay numbers.
check("sub-num", big(3) - big(1), 2);
check("mul-num", big(3) * big(1.5), 4.5);
check("shl-num", big(1) << big(4), 16);
check("unm-num", -big(5), -5);

// Mixed BigInt and Number operands throw, whichever side is wrapped.
throws("mix-sub", function () { return big(3n) - 1; }, TypeError);
throws("mix-sub-right", function () { return 3 - big(1n); }, TypeError);
throws("mix-mul", function () { return big(3n) * big(1); }, TypeError);
throws("mix-div", function () { return big(3n) / 1; }, TypeError);
throws("mix-mod", function () { return big(3n) % 1; }, TypeError);
throws("mix-exp", function () { return big(3n) ** 1; }, TypeError);
throws("mix-shl", function () { return big(3n) << 1; }, TypeError);
throws("mix-shr", function () { return 3 >> big(1n); }, TypeError);
throws("mix-band", function () { return big(3n) & 1; }, TypeError);
throws("mix-bor", function () { return 3 | big(1n); }, TypeError);
throws("mix-bxor", function () { return big(3n) ^ big(1); }, TypeError);
throws("ushr", function () { return big(3n) >>> big(1n); }, TypeError);
throws("unp", function () { return +big(3n); }, TypeError);
throws("mix-sub-imm", function () { return big(3n) - 1; }, TypeError);

// Symbols throw whichever side they appear on.
var sym = { valueOf: function () { return Symbol("s"); } };
throws("sym-sub", function () { return sym - big(1n); }, TypeError);
throws("sym-sub-right", function () { return big(1n) - sym; }, TypeError);
throws("sym-mul", function () { return sym * 1; }, TypeError);
throws("sym-shl", function () { return 1 << sym; }, TypeError);
throws("sym-band", function () { return sym & 1; }, TypeError);
throws("sym-unm", function () { return -sym; }, TypeError);
throws("sym-bnot", function () { return ~sym; }, TypeError);
throws("sym-inc", function () { var s = sym; s++; }, TypeError);

// Conversion order: left is converted before right, each exactly once, and a
// throwing right conversion still happens after the left one.
var log = [];
var L = { valueOf: function () { log.push("L"); return 10n; } };
var R = { valueOf: function () { log.push("R"); return 3n; } };
var Rthrow = { valueOf: function () { log.push("R!"); throw new RangeError("r"); } };
var ops = [
  function () { return L - R; }, function () { return L * R; }, function () { return L / R; },
  function () { return L % R; }, function () { return L ** R; }, function () { return L << R; },
  function () { return L >> R; }, function () { return L & R; }, function () { return L | R; },
  function () { return L ^ R; },
];
for (var i = 0; i < ops.length; i++) {
  log = [];
  ops[i]();
  check("order-" + i, log.join(""), "LR");
}
log = [];
throws("order-throw", function () { return L - Rthrow; }, RangeError);
check("order-throw-log", log.join(""), "LR!");
log = [];
throws("order-mix", function () { return L - big(1); }, TypeError);
check("order-mix-log", log.join(""), "L");

if (fail === 0) print("PASS");
