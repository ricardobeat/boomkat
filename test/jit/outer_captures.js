// Closures that read and write bindings of functions two and three levels out, re-created on every
// call with different captured values: parameters, vars, let/const in blocks, hoisted functions,
// recursion through a captured variable, writes from the inner closure seen by the outer one, a
// binding reassigned after the closures were made, and names a sloppy eval or a nearer declaration
// could shadow.
function deriv(prev, base) {
  var total = 0;
  function bump(n) { total += n; }
  var mid = function(k) {
    let scale = k + 1;
    var inner = function(l, acc) {
      if (l > 0) { bump(1); return inner(l - 1, acc + prev * scale + base); }
      prev = prev + 1;
      return acc;
    };
    return inner(3, 0);
  };
  var r = mid(1) + mid(2);
  base = -base;
  return r + mid(0) + total * 1000 + prev;
}
var s = 0;
for (var i = 0; i < 20000; i++) s += deriv(i % 7, i % 3);
print(s);

function outer(a) {
  return function(b) {
    {
      const c = a * b;
      let d = c + 1;
      return function(e) { d += e; return [a, b, c, d, typeof later, later()]; };
    }
  };
}
function later() { return 1; }
var t = 0;
for (var j = 0; j < 5000; j++) {
  var f = outer(j)(2);
  var v = f(1);
  v = f(3);
  t += v[0] + v[1] + v[2] + v[3] + v[5];
}
print(t);

function shadowed(x) {
  var g = function() { return function() { return x; }; };
  var h = function() { eval("var x = 'shadow'"); return function() { return x; }; };
  return g()() + ":" + h()();
}
var u = "";
for (var q = 0; q < 2000; q++) u = shadowed(q);
print(u);

function named(n) {
  var self = function n2(k) { return function() { return k > 0 ? n + n2(k - 1)() : n; }; };
  return self(3)();
}
var w = 0;
for (var z = 0; z < 3000; z++) w += named(z);
print(w);
