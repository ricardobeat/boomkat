// Indexed reads and stores the inline element paths leave, and MOD and
// `arguments.length`/`arguments[i]`, each past the tier-up threshold: string
// characters, holes and reads past an array's dense part (with and without an
// indexed property on the chain), appends and first stores, a frozen or
// sealed array, arguments objects of each count, for-in index strings, MOD of
// negative and zero operands, doubles, -0 and NaN, and instanceof with a
// primitive left operand.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }
function at(s, i) { return s[i]; }
function get(a, i) { return a[i]; }
function put(a, i, v) { a[i] = v; }
function mod(a, b) { return a % b; }
function same(x, y) { return Object.is(x, y); }
// String characters, in and out of range, and a non-BMP string.
var str = "helloé😀z";
for (var r = 0; r < 3000; r++) {
  var i = r % 12;
  var e = i < str.length ? str.charAt(i) : undefined;
  if (at(str, i) !== e) { check("string " + r, false); break; }
}
check("string symbol-ish", at("abc", -1) === undefined && at("abc", 3) === undefined);
// Holes, past the end, undefined elements.
var holey = [1, , 3, undefined, 5];
holey[20] = 9;
for (var r = 0; r < 3000; r++) {
  var i = r % 25;
  var e = i === 0 ? 1 : i === 2 ? 3 : i === 4 ? 5 : i === 20 ? 9 : undefined;
  if (get(holey, i) !== e) { check("hole " + r, false); break; }
}
check("negative", get([1, 2], -1) === undefined);
var withNamed = [];
Object.defineProperty(withNamed, 5, { get: function () { return "g5"; }, configurable: true });
check("named index", get(withNamed, 5) === "g5" && get(withNamed, 4) === undefined);
// Appends and first stores, growth, length.
for (var r = 0; r < 3000; r++) {
  var a = [];
  put(a, 0, r);
  put(a, 1, "s");
  put(a, 2, { r: r });
  put(a, 40, 1.5);
  if (a.length !== 41 || a[0] !== r || a[1] !== "s" || a[2].r !== r || a[40] !== 1.5 || a[39] !== undefined || 3 in a) { check("append " + r, false); break; }
}
var big = [];
for (var i = 0; i < 20000; i++) put(big, i, i);
check("grow", big.length === 20000 && big[19999] === 19999 && big[1000] === 1000);
var far = [];
put(far, 5000000, 1);
check("far", far.length === 5000001 && far[5000000] === 1 && far[4999999] === undefined);
var sparse = [];
put(sparse, 100, 1); put(sparse, 0, 2);
check("sparse", sparse.length === 101 && Object.keys(sparse).join() === "0,100");
// Stores of undefined and into a hole, with length kept.
var u = [1, 2, 3];
put(u, 5, undefined);
check("undefined store", u.length === 6 && !(5 in u) || 5 in u);
// Frozen, sealed and non-extensible arrays.
for (var r = 0; r < 200; r++) {
  var f = Object.freeze([]), s = Object.seal([]), n = Object.preventExtensions([]);
  put(f, 0, 1); put(s, 0, 1); put(n, 0, 1);
  if (f.length !== 0 || s.length !== 0 || n.length !== 0 || 0 in f || 0 in s || 0 in n) { check("locked " + r, false); break; }
}
function sput(a, i, v) { "use strict"; a[i] = v; }
var thrown = 0;
for (var r = 0; r < 200; r++) {
  try { sput(Object.freeze([]), 0, 1); } catch (e) { thrown++; }
  try { sput(Object.preventExtensions([]), 0, 1); } catch (e) { thrown++; }
}
check("strict locked", thrown === 400);
// for-in index strings.
var items = [10, 20, , 40];
var got = [];
for (var r = 0; r < 600; r++) { got = []; for (var k in items) got.push(get(items, k)); }
check("for-in", got.join() === "10,20,40");
check("for-in hole", get(items, "2") === undefined && get(items, "9") === undefined && get(items, "1") === 20);
check("string key on array", get(items, "length") === 4 && get(items, "-1") === undefined);
// arguments.
function args() { return arguments.length * 100 + (arguments.length > 0 ? arguments[0] : -1) + (arguments.length > 1 ? arguments[1] : 0); }
function sl() { var n = 0; for (var i = 0; i < arguments.length; i++) n += arguments[i]; return n; }
for (var r = 0; r < 3000; r++) {
  var n = r % 6;
  var a = []; for (var j = 0; j < n; j++) a.push(j + 1);
  var e = sl.apply(null, a);
  if (sl.apply(null, a) !== e || args.apply(null, a) !== n * 100 + (n > 0 ? 1 : -1) + (n > 1 ? 2 : 0)) { check("arguments " + r, false); break; }
}
function mapped(a) { arguments[0] = 7; var l = arguments.length; arguments.length = 9; return a + "," + l + "," + arguments.length; }
for (var r = 0; r < 300; r++) if (mapped(1, 2) !== "7,2,9") { check("mapped " + r, false); break; }
function strictArgs() { "use strict"; return arguments.length; }
check("strict args", strictArgs(1, 2, 3) === 3);
function undefArgs() { return arguments.length + ":" + arguments[0] + ":" + arguments[1]; }
for (var r = 0; r < 300; r++) if (undefArgs(undefined, 2) !== "2:undefined:2") { check("undefined arg " + r, false); break; }
// MOD.
var modCases = [[7, 3, 1], [-7, 3, -1], [7, -3, 1], [-7, -3, -1], [6, 3, 0], [-6, 3, -0], [5, 0, NaN], [0, 5, 0], [-0, 5, -0],
  [5.5, 2, 1.5], [-5.5, 2, -1.5], [5, 2.5, 0], [1e300, 7, 1e300 % 7], [2 ** 40 + 1, 7, (2 ** 40 + 1) % 7], [Infinity, 2, NaN], [5, Infinity, 5],
  [NaN, 2, NaN], [2, NaN, NaN], ["7", 4, 3], [7, "4", 3], [null, 3, 0], [undefined, 3, NaN], [true, 2, 1], [1 / 3, 1, 1 / 3], [0, -5, 0], [-0, -5, -0]];
for (var r = 0; r < 3000; r++) {
  var m = modCases[r % modCases.length];
  if (!same(mod(m[0], m[1]), m[2])) { check("mod " + m[0] + " % " + m[1] + " = " + mod(m[0], m[1]), false); break; }
}
check("mod bigint", mod(7n, 4n) === 3n);
var side = 0;
check("mod valueOf", mod({ valueOf: function () { side++; return 9; } }, 4) === 1 && side === 1);
var sum = 0;
for (var i = 0; i < 100000; i++) sum += i % 7;
check("mod loop", sum === 299995);
// instanceof with a primitive left operand and a cold hasInstance cache.
function Cold() {}
var primitives = [1, "s", true, undefined, null, Symbol("p"), 10n, 2.5];
for (var r = 0; r < 3000; r++) {
  if (primitives[r % primitives.length] instanceof Cold) { check("primitive instanceof " + r, false); break; }
}
for (var r = 0; r < 3000; r++) {
  if (!(Math.max instanceof Function) || !(JSON.parse instanceof Object) || Math.max instanceof Cold) { check("lightfunc instanceof " + r, false); break; }
}
check("instanceof object", new Cold instanceof Cold && !({} instanceof Cold));
// Last: an index on Array.prototype or Object.prototype turns the fast paths off for good.
// A hole read through an indexed property on the chain.
Array.prototype[7] = "proto7";
check("chain hole", get(holey, 7) === "proto7" && get([], 7) === "proto7" && get([1], 7) === "proto7");
delete Array.prototype[7];
check("chain removed", get(holey, 7) === undefined);
Object.prototype[3] = "obj3";
check("object chain", get([], 3) === "obj3" && get([0, 1], 3) === "obj3");
delete Object.prototype[3];
check("object chain removed", get([], 3) === undefined);
// A setter on the prototype chain intercepts a new index.
var hits = 0;
Object.defineProperty(Array.prototype, "9", { set: function (v) { hits++; }, configurable: true });
var s9 = [];
put(s9, 9, 1);
check("proto setter", hits === 1 && s9.length === 0);
delete Array.prototype[9];
put(s9, 9, 2);
check("proto setter gone", s9.length === 10 && s9[9] === 2);
print(bad.length === 0 ? "elements ok" : "elements FAIL " + bad.join(" | "));
