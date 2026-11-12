// Callees that need a function scope of their own enter through their call entry, which creates
// the scope (vm::jit_entry_scope): closures over parameters and locals, a named function
// expression's own binding, a closure made in a block whose lexical scope must stay visible, a
// constructor, plain and method calls, recursion, and a default parameter, which keeps the
// helper path. Results match the interpreter.
function counter(start) {
  var n = start;
  return function () { return ++n; };
}
function adder(a, b) {
  function inner() { return a + b; }
  return inner();
}
var fact = function self(k) {
  var f = function () { return k <= 1 ? 1 : k * self(k - 1); };
  return f();
};
function blockClosure(x) {
  let out = 0;
  {
    let y = x * 2;
    var g = function (z) { var w = z; return function () { return y + w + x; }; };
    out = g(1)();
  }
  return out;
}
function Point(x, y) {
  this.x = x;
  this.norm = function () { return x * x + y * y; };
}
var obj = {
  base: 10,
  scaled: function (k) { var self = this; return (function () { return self.base * k; })(); }
};
function strictPlain(v) { "use strict"; var c = function () { return v + 1; }; return c(); }
function depth(n) { var keep = function () { return n; }; return n === 0 ? keep() : depth(n - 1) + keep(); }
function defaults(a, b = 5) { var h = function () { return a + b; }; return h(); }

var s = 0;
var c = counter(0);
for (var i = 0; i < 30000; i++) {
  s = (s + adder(i, 1)) | 0;
  s = (s + c()) | 0;
  s = (s + blockClosure(i & 63)) | 0;
  s = (s + new Point(i & 7, 2).norm()) | 0;
  s = (s + obj.scaled(i & 3)) | 0;
  s = (s + strictPlain(i)) | 0;
  s = (s + defaults(i) + defaults(i, 1)) | 0;
  if ((i & 1023) === 0) s = (s + fact(6) + depth(40)) | 0;
}
print(s);
