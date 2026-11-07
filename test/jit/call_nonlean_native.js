// Callees the lean call shapes decline (a scope object of their own, class constructors, named
// function expressions, mapped arguments, rest parameters, throws) run as nested native calls and
// must agree with the interpreter, including exceptions crossing the frames.
function withScope(n) { var k = n; return function () { return k + 1; }; }
function withScopeSum(n) { var f = withScope(n); var g = withScope(n + 1); return f() + g(); }
class Box { constructor(v) { this.v = v; } get() { return this.v; } }
function viaClass(i) { var b = new Box(i); return b.get() * 2; }
var named = function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); };
function mapped(a, b) { arguments[0] = 9; return a + b; }
function rest(first, ...others) { return first + others.length; }
function thrower(n) { var o = { n: n }; var f = function () { if (o.n % 7 == 3) throw new RangeError("r" + o.n); return o.n; }; return f(); }
function catcher(n) { try { return thrower(n); } catch (e) { return e.message; } }
function deep(n) { var c = n; var f = function () { return c; }; return n == 0 ? f() : 1 + deep(n - 1) + f() - c; }
var out = [];
for (var i = 0; i < 600; i++) {
  out.push(withScopeSum(i), viaClass(i), named(i % 10), mapped(i, 1), rest(i, 1, 2, 3), catcher(i));
}
out.push(deep(60));
var h = 0;
for (var k = 0; k < out.length; k++) {
  var s = String(out[k]);
  for (var m = 0; m < s.length; m++) h = (h * 31 + s.charCodeAt(m)) | 0;
}
console.log(out.length, h, out.slice(-4).join(","));
