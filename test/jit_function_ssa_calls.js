// Fused variable/global calls expand into SSA without a temporary callee frame.
// Repeated binding reads share an entry snapshot, but every miss must preserve
// the interpreter's coercion and call semantics.
function ssaMix(a, b) { return a * 1.001 + b; }
function ssaMixRegion(a, b) {
  var x = a + b;
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  x = ssaMix(x, a);
  return x;
}
function mixReference(a, b) {
  var x = a + b;
  for (var i = 0; i < 20; i++) x = x * 1.001 + a;
  return x;
}
for (var i = 0; i < 500; i++) {
  if (!Object.is(ssaMixRegion(i, 3), mixReference(i, 3))) throw Error('SSA leaf calls');
}
var effects = 0;
var value = {valueOf: function () { effects++; return 2; }};
if (!Object.is(ssaMixRegion(value, 3), mixReference(2, 3)) || effects !== 21) throw Error('SSA call coercion');
var original = ssaMix;
ssaMix = function (a, b) { effects++; return a * 1.001 + b; };
effects = 0;
if (!Object.is(ssaMixRegion(2, 3), mixReference(2, 3)) || effects !== 20) throw Error('SSA call rebind');
ssaMix = original.bind(null);
if (!Object.is(ssaMixRegion(2, 3), mixReference(2, 3))) throw Error('SSA bound call');
ssaMix = new Proxy(original, {apply: function (fn, self, args) { effects++; return fn(args[0], args[1]); }});
effects = 0;
if (!Object.is(ssaMixRegion(2, 3), mixReference(2, 3)) || effects !== 20) throw Error('SSA proxy call');
ssaMix = original;
// SSA loops can now admit the same leaves. Their misses publish the exact
// caller state instead of using the template tier's builtin-call protocol.
function ssaLeafLoop(n) {
  var x = 0.25;
  for (var i = 0; i < n; i++) x = ssaMix(x, 1);
  return x;
}
function loopReference(n) {
  var x = 0.25;
  for (var i = 0; i < n; i++) x = x * 1.001 + 1;
  return x;
}
for (var i = 0; i < 100; i++) {
  if (!Object.is(ssaLeafLoop(100), loopReference(100))) throw Error('SSA loop calls');
}
ssaMix = function (a, b) { effects++; return a * 1.001 + b; };
effects = 0;
if (!Object.is(ssaLeafLoop(100), loopReference(100)) || effects !== 100) throw Error('SSA loop call miss');
// Unary plus in an expanded callee still performs ToNumber.
function ssaPlus(a) { return +a; }
function plusRegion(a) {
  var x = ssaPlus(a);
  x = x * 1.01 + 1;
  x = x * 1.01 + 1;
  x = x * 1.01 + 1;
  return x;
}
for (var i = 0; i < 100; i++) plusRegion(i);
var expected = ((2 * 1.01 + 1) * 1.01 + 1) * 1.01 + 1;
if (plusRegion('2') !== expected) throw Error('SSA unary plus');
print('Function SSA calls: PASS');
