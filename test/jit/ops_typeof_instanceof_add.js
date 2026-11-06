// typeof of every value class, instanceof (plain, bound, Symbol.hasInstance,
// proxy in the chain, accessor prototype, primitives, non-callable RHS) and
// ADD that concatenates or coerces, each run past the tier-up threshold.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function ty(x) { return typeof x; }
var sym = Symbol("s");
var fn = function () {};
class K {}
var vals = [[undefined, "undefined"], [null, "object"], [true, "boolean"], [1, "number"], [2.5, "number"],
  [NaN, "number"], [-0, "number"], ["s", "string"], [sym, "symbol"], [10n, "bigint"], [{}, "object"],
  [[], "object"], [fn, "function"], [K, "function"], [Math.max, "function"], [fn.bind(null), "function"],
  [new Proxy(fn, {}), "function"], [new Proxy({}, {}), "object"], [/x/, "object"], [new Date(0), "object"],
  [new Number(1), "object"], [2 ** 40, "number"], ["a" + 1, "string"]];
for (var r = 0; r < 4000; r++) {
  var e = vals[r % vals.length];
  if (ty(e[0]) !== e[1]) { check("typeof " + r + " " + e[1], false); break; }
}
function io(a, b) { return a instanceof b; }
function A() {}
function B() {}
B.prototype = Object.create(A.prototype);
var viaHas = { [Symbol.hasInstance](v) { return v === 1; } };
function Bad() {}
Bad.prototype = 1;
var proxied = Object.create(new Proxy(A.prototype, {}));
var cases = [[new A, A, true], [new B, A, true], [new A, B, false], [{}, A, false], [1, A, false], ["s", A, false],
  [null, A, false], [new B, A.bind(null), true], [1, viaHas, true], [2, viaHas, false], [proxied, A, false], [Object.create(new Proxy(new A, {})), A, true], [Object.create(null), A, false], [A.prototype, A, false], [[], Array, true], [[], Object, true],
  [fn, Function, true], [new K, K, true]];
for (var r = 0; r < 4000; r++) {
  var c = cases[r % cases.length];
  if (io(c[0], c[1]) !== c[2]) { check("instanceof " + r + " " + (r % cases.length), false); break; }
}
for (var r = 0; r < 100; r++) {
  var threw = false;
  try { io({}, {}); } catch (e) { threw = e instanceof TypeError; }
  check("non-callable rhs", threw);
  threw = false;
  try { io({}, Bad); } catch (e) { threw = e instanceof TypeError; }
  check("non-object prototype", threw && io(1, Bad) === false);
  threw = false;
  try { io({}, 1); } catch (e) { threw = e instanceof TypeError; }
  check("primitive rhs", threw);
}
function add(a, b) { return a + b; }
var obj = { toString() { return "O"; } }, val = { valueOf() { return 7; } };
var adds = [["a", "b", "ab"], ["k", 5, "k5"], [5, "k", "5k"], ["x", 1.5, "x1.5"], [1.5, "x", "1.5x"], ["x", -3, "x-3"],
  ["x", 2 ** 50, "x1125899906842624"], ["x", undefined, "xundefined"], ["x", null, "xnull"], [true, "x", "truex"],
  ["x", obj, "xO"], [obj, 1, "O1"], [val, 1, 8], [1, 2, 3], [2 ** 47, 2 ** 47, 2 ** 48], [1.5, 2.5, 4], [undefined, 1, NaN],
  [null, 1, 1], [1n, 2n, 3n], ["", "", ""], ["x", [1, 2], "x1,2"], [{}, "x", "[object Object]x"]];
for (var r = 0; r < 4000; r++) {
  var c = adds[r % adds.length];
  var got = add(c[0], c[1]);
  if (!Object.is(got, c[2])) { check("add " + r + " " + (r % adds.length) + " " + String(got), false); break; }
}
check("symbol add", (function () { try { add("x", sym); } catch (e) { return e instanceof TypeError; } })());
var s = "";
for (var i = 0; i < 20000; i++) s = add(s, "ab" + (i % 10));
check("accumulate", s.length === 60000 && s.slice(0, 6) === "ab0ab1" && s.slice(-3) === "ab9");
var key = "String for key ";
var keys = {};
for (var i = 0; i < 3000; i++) keys[add(key, i)] = i;
check("keys", keys["String for key 2999"] === 2999 && Object.keys(keys).length === 3000);
var big = "x".repeat(2 ** 29);
check("too long", (function () { try { add(big, big); add(big, big); return false; } catch (e) { return e instanceof RangeError; } })());
if (bad.length) throw new Error("failed: " + bad.join(", "));
print("ok");
