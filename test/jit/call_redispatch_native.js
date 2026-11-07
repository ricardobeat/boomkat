// Function.prototype.call and apply from native code enter a compiled callee as a native call
// (a throw, an arguments object, a primitive `this` and recursion through call must agree with
// the interpreter).
function Base(x) { this.x = x; }
function Derived(x, y) { Base.call(this, x); this.y = y; }
function viaApply(a, b) { return Base.apply(this, [a, b]); }
function thrower(n) { if (n > 2) throw new Error("boom" + n); return n; }
function useArgs() { return arguments.length + arguments[0]; }
var out = [];
for (var i = 0; i < 400; i++) {
  var d = new Derived(i, i + 1); out.push(d.x + d.y);
  var o = {}; viaApply.call(o, i, 2); out.push(o.x);
  try { thrower.call(null, i % 5); out.push("ok"); } catch (e) { out.push(e.message); }
  out.push(useArgs.call(null, i, 2, 3));
  out.push([1, 2, 3].map(function (v) { return v * this.k; }, { k: i }).join());
  out.push(Array.prototype.slice.call("abc", 1).join(""));
  var f = function () { "use strict"; return this === undefined ? "u" : typeof this; };
  out.push(f.call(5) + f.call("s") + f.call(undefined) + f.call(null));
}
function deep(n) { return n == 0 ? 0 : 1 + deep.call(null, n - 1); }
out.push(deep(500));
function str(i) { return "s" + i; }
function viaStr(i) { var s = str(i); return s + s; }
for (var j = 0; j < 400; j++) out.push(viaStr(j));
var h = 0;
for (var k = 0; k < out.length; k++) {
  var s = String(out[k]);
  for (var m = 0; m < s.length; m++) h = (h * 31 + s.charCodeAt(m)) | 0;
}
console.log(out.length, h, out.slice(-3).join(","));
