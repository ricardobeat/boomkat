// Variable access in compiled code: reads, assignments and increments of
// bindings in enclosing scopes across activations (whose scope chains differ
// in shape, so the cached entries re-arm), assignments to globals and to names
// that resolve late, closure cells, and `var` declarations of each value class.
var bad = [];
function check(name, ok) { if (!ok) bad.push(name); }

// Scope chains of one function that differ in shape: eval adds a binding to
// some activations only.
function mkCounter(withEval, start) {
  var n = start, s = "s";
  if (withEval) eval("var extra = 1");
  function bump() { n++; s = s + "x"; return n; }
  function peek() { return n + s.length; }
  return { bump: bump, peek: peek, get n() { return n; } };
}
var cs = [];
for (var i = 0; i < 6; i++) cs.push(mkCounter(i % 2 === 0, i * 100));
for (var r = 0; r < 500; r++) {
  for (var i = 0; i < cs.length; i++) {
    cs[i].bump();
    if (cs[i].n !== i * 100 + r + 1 || cs[i].peek() !== cs[i].n + r + 2) { check("counters " + i + " " + r, false); r = 1e9; break; }
  }
}

// INC_VAR: a fastint that overflows to a double, a string, a BigInt, undefined,
// and a const.
function mkInc(v) { var x = v; return function () { x++; return x; }; }
var big = mkInc(140737488355326);
check("inc edge", big() === 140737488355327 && big() === 140737488355328 && big() === 140737488355329);
var str = mkInc("5");
check("inc str", str() === 6 && str() === 7);
var und = mkInc(undefined);
check("inc undef", isNaN(und()));
var bi = mkInc(1n);
check("inc bigint", bi() === 2n && bi() === 3n);
var dbl = mkInc(0.5);
check("inc double", dbl() === 1.5 && dbl() === 2.5);
function constInc() { const c = 1; return function () { try { c++; } catch (e) { return e instanceof TypeError; } return false; }; }
check("inc const", constInc()() && constInc()());
for (var r = 0; r < 300; r++) {
  var f = mkInc(r);
  if (f() !== r + 1 || f() !== r + 2) { check("inc loop " + r, false); break; }
}

// A plain assignment resolves its target before the right-hand side runs.
var late1;
function lateGlobal(k) { late1 = (globalThis.late2 = k, k + 1); return late1; }
for (var r = 0; r < 300; r++) if (lateGlobal(r) !== r + 1 || globalThis.late2 !== r) { check("late global " + r, false); break; }
function implicitGlobal(k) { implicit1 = k; return implicit1; }
for (var r = 0; r < 300; r++) if (implicitGlobal(r) !== r) { check("implicit " + r, false); break; }
check("implicit prop", Object.getOwnPropertyDescriptor(globalThis, "implicit1").configurable === true);
function strictUnresolved(k) { "use strict"; nope1 = k; }
for (var r = 0; r < 300; r++) {
  var t = false;
  try { strictUnresolved(r); } catch (e) { t = e instanceof ReferenceError; }
  if (!t) { check("strict unresolved " + r, false); break; }
}
function strictLate(k) { "use strict"; nope2 = (globalThis.nope2 = k, k); }
for (var r = 0; r < 300; r++) {
  var t = false;
  try { strictLate(r); } catch (e) { t = e instanceof ReferenceError; }
  delete globalThis.nope2;
  if (!t) { check("strict late " + r, false); break; }
}
// The binding disappears between resolution and store.
function gone(k) { implicit2 = (delete globalThis.implicit2, k); return globalThis.implicit2; }
globalThis.implicit2 = 0;
for (var r = 0; r < 300; r++) { globalThis.implicit2 = 0; if (gone(r) !== r) { check("gone " + r, false); break; } }

// Assignments to bindings in a scope that eval makes dynamic: counted strings
// replacing counted strings, objects replacing objects, under collector work.
function dyn(n) {
  eval("var tag = 'e'");
  var s = "", o = null, k = 0;
  for (var i = 0; i < n; i++) { s = s + "ab"; o = { i: i, s: s.length }; k = k + i; tag = "t" + i; }
  return s.length + o.i + o.s + k + tag.length;
}
for (var r = 0; r < 400; r++) {
  var n = 5 + (r % 7);
  if (dyn(n) !== 2 * n + (n - 1) + 2 * n + n * (n - 1) / 2 + ("t" + (n - 1)).length) { check("dyn " + r, false); break; }
}

// Assignments to `let` bindings of a block scope: counted strings replacing
// counted strings, objects replacing objects, numbers replacing both.
function lets(n) {
  let s = "", o = { i: -1 }, k = 0;
  for (let i = 0; i < n; i++) { s = s + "ab"; o = { i: i }; k = k + i; if (i % 3 === 0) k = "k"; if (i % 3 === 1) k = 1; }
  { let z = 1; return () => z + s.length + o.i + (typeof k === "string" ? 0 : k); }
}
for (var r = 0; r < 1500; r++) {
  var n = 1 + (r % 9), want = 1 + 2 * n + (n - 1), kk = 0;
  for (var i = 0; i < n; i++) { kk = kk + i; if (i % 3 === 0) kk = "k"; if (i % 3 === 1) kk = 1; }
  want += typeof kk === "string" ? 0 : kk;
  if (lets(n)() !== want) { check("lets " + r, false); break; }
}
// Global stores of each value class, then a read-only global.
var g = 0;
function setG(v) { g = v; }
var gv = [1, 2.5, "str", { o: 1 }, null, undefined, true, 2 ** 40, [1], 7n];
for (var r = 0; r < 1000; r++) { var v = gv[r % gv.length]; setG(v); if (g !== v) { check("global store " + r, false); break; } }
Object.defineProperty(globalThis, "g", { writable: false, value: 5, configurable: false });
setG(9);
check("readonly global", g === 5);
// Closure cells: per-iteration bindings, every value class, objects stored
// into a long-lived cell, and a binding assigned from inner functions.
var fs = [];
for (let i = 0; i < 40; i++) { let c = i; fs.push(function () { c = c + 1; return c + i; }); }
for (var r = 0; r < 20; r++) for (var i = 0; i < fs.length; i++) if (fs[i]() !== 2 * i + r + 1) { check("cells " + i + " " + r, false); r = 1e9; break; }
function cellKinds() {
  var k = 0, last;
  function set(v) { last = v; k++; return last; }
  function get() { return last; }
  return { set: set, get: get };
}
var ck = cellKinds();
for (var r = 0; r < 600; r++) { var v = gv[r % gv.length]; ck.set(v); if (ck.get() !== v) { check("cell kind " + r, false); break; } }
var keep = [];
function cellHolder(i) { var o = { i: i }, s = "s" + i, a = [i]; return function () { o = { i: o.i + 1 }; s = s + "."; a = [a[0] + 1]; return o.i + s.length + a[0]; }; }
for (var r = 0; r < 30000; r++) {
  var h = cellHolder(r);
  var x = h();
  if (x !== r + 1 + ("s" + r).length + 1 + r + 1) { check("cell gc " + r, false); break; }
  if (r % 500 === 0) keep.push(h);
}
for (var i = 0; i < keep.length; i++) { var r0 = i * 500; if (keep[i]() !== r0 + 2 + ("s" + r0).length + 2 + r0 + 2) { check("cell keep " + i, false); break; } }

// `var` declarations: the value classes, repeated calls on one shape, a call
// after the function's scope was extended by eval, and a hoisted function.
function decls(i, kind) {
  var a = i, b = "b" + i, c = { c: i }, d = kind ? 1.5 : undefined, e = function () { return a; }, f = [i];
  var g2 = kind === 2 ? i : null;
  return a + b.length + c.c + (d === undefined ? 0 : d) + e() + f[0] + (g2 === null ? 0 : g2);
}
for (var r = 0; r < 3000; r++) {
  var kind = r % 3;
  var want = r + ("b" + r).length + r + (kind ? 1.5 : 0) + r + r + (kind === 2 ? r : 0);
  if (decls(r, kind) !== want) { check("decls " + r, false); break; }
}
function declEval(i, ev) {
  if (ev) eval("var injected = 5");
  var a = i, b = 2;
  return a + b + (ev ? injected : 0);
}
for (var r = 0; r < 600; r++) if (declEval(r, r % 4 === 0) !== r + 2 + (r % 4 === 0 ? 5 : 0)) { check("decl eval " + r, false); break; }
function hoist(i) { return inner(); function inner() { return i; } var after = 1; }
for (var r = 0; r < 600; r++) if (hoist(r) !== r) { check("hoist " + r, false); break; }
function declObjs(n) { var arr = []; for (var i = 0; i < n; i++) { var o = { v: i }; arr.push(o); } return arr[n - 1].v; }
var sink = [];
for (var r = 0; r < 40000; r++) { var v = declObjs(3); sink.push(v); if (sink.length > 100) sink.length = 0; if (v !== 2) { check("decl objs " + r, false); break; } }

// TDZ and constants through compiled code.
function tdz() { try { return later + 1; } catch (e) { return e instanceof ReferenceError; } let later = 1; }
for (var r = 0; r < 300; r++) if (tdz() !== true) { check("tdz " + r, false); break; }
function constAssign() { const k = 1; try { k = 2; } catch (e) { return e instanceof TypeError; } return false; }
for (var r = 0; r < 300; r++) if (!constAssign()) { check("const assign " + r, false); break; }

// A scope introduced by `with` between uses.
function withScope(o, k) { var x = k; with (o) { x = x + 1; y = x; } return x; }
for (var r = 0; r < 300; r++) {
  var o1 = r % 2 ? { x: 100 } : {};
  var wv = withScope(o1, r);
  if (r % 2 ? (wv !== r || o1.x !== 101) : (wv !== r + 1)) { check("with " + r, false); break; }
}
print(bad.length === 0 ? "vars ok" : "vars FAIL " + bad.join(","));
