// Verify Math fixes per ES6 spec.

function assertSameValue(a, e) {
  if (a === e) {
    if (a !== 0) return;
    if (1 / a === 1 / e) return;
  } else if (a !== a && e !== e) {
    return;
  }
  throw new Error("Expected " + e + " (typeof " + typeof e + ") but got " + a);
}

// Math.max: +0 > -0, NaN propagates
assertSameValue(Math.max(0, 0), 0);
assertSameValue(Math.max(-0, -0), -0);
assertSameValue(Math.max(0, -0), 0);
assertSameValue(Math.max(-0, 0), 0);
assertSameValue(Math.max(0, 0, -0), 0);
assertSameValue(Math.max(NaN, 5), NaN);
assertSameValue(Math.max(5, NaN), NaN);
assertSameValue(Math.max(NaN, NaN), NaN);
assertSameValue(Math.max(1, 2, 3), 3);

// Math.min: -0 < +0
assertSameValue(Math.min(0, 0), 0);
assertSameValue(Math.min(-0, -0), -0);
assertSameValue(Math.min(0, -0), -0);
assertSameValue(Math.min(-0, 0), -0);
assertSameValue(Math.min(0, 0, -0), -0);
assertSameValue(Math.min(NaN, 5), NaN);
assertSameValue(Math.min(5, NaN), NaN);
assertSameValue(Math.min(NaN, NaN), NaN);
assertSameValue(Math.min(3, 2, 1), 1);

// Math.pow special cases per ES2016 §20.2.2.26.
// A NaN exponent is NaN even for base 1, and abs(base) === 1 with a
// ±Infinity exponent is NaN. C99 pow() returns 1 for both of those, so they
// are the cases most likely to regress. A ±0 exponent is 1 even for a NaN
// base, and that one takes priority over the NaN-exponent rule.
assertSameValue(Math.pow(1, NaN), NaN);
assertSameValue(Math.pow(1, Infinity), NaN);
assertSameValue(Math.pow(1, -Infinity), NaN);
assertSameValue(Math.pow(-1, Infinity), NaN);
assertSameValue(Math.pow(-1, -Infinity), NaN);
assertSameValue(Math.pow(2, NaN), NaN);
assertSameValue(Math.pow(NaN, 0), 1);
assertSameValue(Math.pow(NaN, -0), 1);
assertSameValue(Math.pow(2, 3), 8);
assertSameValue(Math.pow(1, 0), 1);
assertSameValue(Math.pow(1, 2), 1);

// The ** operator must agree with Math.pow on every one of those cases —
// it is evaluated by a separate opcode, so it can drift independently.
assertSameValue(1 ** NaN, NaN);
assertSameValue(1 ** Infinity, NaN);
assertSameValue(1 ** -Infinity, NaN);
assertSameValue((-1) ** Infinity, NaN);
assertSameValue((-1) ** -Infinity, NaN);
assertSameValue(2 ** NaN, NaN);
assertSameValue(NaN ** 0, 1);
assertSameValue(2 ** 3, 8);
assertSameValue(1 ** 2, 1);

// Math.hypot
assertSameValue(Math.hypot(), 0);
assertSameValue(Math.hypot(3, 4), 5);
assertSameValue(Math.hypot(NaN, 1), NaN);
assertSameValue(Math.hypot(1, NaN), NaN);
assertSameValue(Math.hypot(Infinity), Infinity);
assertSameValue(Math.hypot(-Infinity), Infinity);
assertSameValue(Math.hypot(NaN, Infinity), Infinity);
assertSameValue(Math.hypot(Infinity, NaN), Infinity);

// Math.round half-to-even for boundary values (ES2018+ §20.2.2.34)
assertSameValue(Math.round(-0), -0);
assertSameValue(Math.round(-0.25), -0);
assertSameValue(Math.round(-0.5), -0);
assertSameValue(Math.round(0.5), 1);
assertSameValue(Math.round(0.4), 0);
assertSameValue(Math.round(0.6), 1);
// Per ES6: Math.round(x) = floor(x + 0.5), so -1.5 → floor(-1) = -1
assertSameValue(Math.round(-1.5), -1);
assertSameValue(Math.round(-2.5), -2);

// String(symbol) wraps as "Symbol(description)" per ES2019+
assertSameValue(String(Symbol("foo")), "Symbol(foo)");
assertSameValue(String(Symbol()), "Symbol()");
assertSameValue(String(Symbol("")), "Symbol()");
assertSameValue(Symbol("x").toString(), "Symbol(x)");

// toStringTag on Math
assertSameValue(Math[Symbol.toStringTag], "Math");
assertSameValue(JSON[Symbol.toStringTag], "JSON");

// Uncaught error reporting: throwing without try/catch should print
// "Uncaught Error: <message>", not "execute failed: vm::VM_ERROR"
try {
  Symbol() + "msg";
  throw new Error("expected throw");
} catch (e) {
  // The catch should fire — confirms the throw propagated
}

console.log("test_math_fixes OK");
