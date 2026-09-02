// ToNumber(symbol) throws (ES2023 7.1.4), including inside the Math builtins,
// where the argument coercion used to swallow the error and yield NaN.
var pass = 0;

function throwsTypeError(name, fn) {
  try {
    fn();
    print("FAIL: " + name + " did not throw");
  } catch (e) {
    if (e instanceof TypeError) { pass = pass + 1; }
    else { print("FAIL: " + name + " threw " + e.constructor.name); }
  }
}

function returns(name, fn, expected) {
  var actual = fn();
  if (actual === expected) { pass = pass + 1; }
  else { print("FAIL: " + name + " gave " + actual + ", expected " + expected); }
}

var sym = Symbol("s");

throwsTypeError("Math.max(symbol)", function () { return Math.max(sym); });
throwsTypeError("Math.min(symbol)", function () { return Math.min(sym); });
throwsTypeError("Math.abs(symbol)", function () { return Math.abs(sym); });
throwsTypeError("Math.round(symbol)", function () { return Math.round(sym); });
throwsTypeError("Math.max(1, symbol)", function () { return Math.max(1, sym); });

// The other ToNumber paths already threw and must keep doing so.
throwsTypeError("Number(symbol)", function () { return Number(sym); });
throwsTypeError("unary plus", function () { return +sym; });
throwsTypeError("symbol * 2", function () { return sym * 2; });

// Coercible arguments are unaffected.
returns("Math.max(1, 2)", function () { return Math.max(1, 2); }, 2);
returns("Math.max()", function () { return Math.max(); }, -Infinity);
returns("Math.min('3', 4)", function () { return Math.min("3", 4); }, 3);
returns("Math.abs(-5)", function () { return Math.abs(-5); }, 5);
returns("Math.max(valueOf)", function () {
  return Math.max({ valueOf: function () { return 7; } }, 2);
}, 7);
returns("Math.max(null)", function () { return Math.max(null); }, 0);

print("pass:", pass);
