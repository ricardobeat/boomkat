// A builtin is a LIGHTFUNC TVal, not a heap object, so IsCallable checks that
// only test is_object() reject it. Every callback and comparator position
// below must accept one.
var pass = 0;

function ok(name, fn) {
  try { fn(); pass = pass + 1; }
  catch (e) { print("FAIL: " + name + " threw " + e.constructor.name); }
}

function throwsTypeError(name, fn) {
  try { fn(); print("FAIL: " + name + " did not throw"); }
  catch (e) {
    if (e instanceof TypeError) { pass = pass + 1; }
    else { print("FAIL: " + name + " threw " + e.constructor.name); }
  }
}

function equals(name, actual, expected) {
  if (actual === expected) { pass = pass + 1; }
  else { print("FAIL: " + name + " gave " + actual + ", expected " + expected); }
}

var a = [1, 2, 3];
ok("Array map", function () { return a.map(Math.max); });
ok("Array filter", function () { return a.filter(Math.max); });
ok("Array forEach", function () { return a.forEach(Math.max); });
ok("Array some", function () { return a.some(Math.max); });
ok("Array every", function () { return a.every(Math.max); });
ok("Array find", function () { return a.find(Math.max); });
ok("Array reduce", function () { return a.reduce(Math.max); });
ok("Array flatMap", function () { return a.flatMap(Math.max); });
ok("Array sort", function () { return a.slice().sort(Math.max); });
ok("Array toSorted", function () { return a.toSorted(Math.max); });
ok("Array.from mapfn", function () { return Array.from(a, Math.max); });

ok("TypedArray map", function () { return new Uint8Array([1, 2]).map(Math.max); });
ok("TypedArray filter", function () { return new Uint8Array([1, 2]).filter(Math.max); });
ok("TypedArray sort", function () { return new Uint8Array([2, 1]).sort(Math.max); });
ok("TypedArray toSorted", function () { return new Uint8Array([2, 1]).toSorted(Math.max); });

// Non-callables are still rejected.
throwsTypeError("map(null)", function () { return a.map(null); });
throwsTypeError("map(0)", function () { return a.map(0); });
throwsTypeError("map({})", function () { return a.map({}); });
throwsTypeError("sort(null)", function () { return a.slice().sort(null); });
throwsTypeError("TypedArray map(null)", function () { return new Uint8Array([1]).map(null); });
throwsTypeError("TypedArray sort(0)", function () { return new Uint8Array([1]).sort(0); });

// Ordinary callbacks keep working.
equals("map doubles", [1, 2, 3].map(function (x) { return x * 2; }).join(), "2,4,6");
equals("filter keeps", [1, 2, 3].filter(function (x) { return x > 1; }).join(), "2,3");
equals("reduce sums", [1, 2, 3].reduce(function (p, c) { return p + c; }, 0), 6);
equals("sort orders", [3, 1, 2].sort(function (x, y) { return x - y; }).join(), "1,2,3");

// A builtin trap that coerces the proxy it guards recurses through native
// frames; it must end in a throw rather than exhausting the C stack.
throwsTypeError("proxy get trap coercing its own proxy", function () {
  return new Proxy({}, { get: Math.max }).x;
});

print("pass:", pass);
