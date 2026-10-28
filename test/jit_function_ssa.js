// Exercise a scalar body too large for the small general inliner, including
// type changes after native warmup and observable coercion on fallback.
function scalarRegion(a, b) {
  var x = a + b;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  return x;
}
function reference(a, b) {
  var x = a + b;
  for (var i = 0; i < 30; i++) x = x * 1.001 + a;
  return x;
}
for (var i = 0; i < 500; i++) {
  if (!Object.is(scalarRegion(i & 31, 3), reference(i & 31, 3))) throw Error('scalar region');
}
var values = [2.5, -0, NaN, Infinity, '2', undefined];
for (var i = 0; i < values.length; i++) {
  if (!Object.is(scalarRegion(values[i], 3), reference(values[i], 3))) throw Error('region type change');
}
var calls = 0;
var value = {valueOf: function () { calls++; return 2; }};
if (!Object.is(scalarRegion(value, 3), reference(2, 3)) || calls !== 31) throw Error('region coercion');
print('Function SSA: PASS');
