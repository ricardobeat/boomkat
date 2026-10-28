// Own-field SSA guards share a layout check across several slots. Type or
// shape misses must replay the original frame before any observable coercion.
function dotFields(v) {
  return this.x * v.x + this.y * v.y + this.z * v.z;
}
var left = {x: 2, y: 3, z: 5, dot: dotFields};
var right = {x: 7, y: 11, z: 13};
for (var i = 0; i < 1000; i++) {
  if (left.dot(right) !== 112) throw Error('field region');
}
right.y = 0.5;
if (left.dot(right) !== 80.5) throw Error('field type change');
right.extra = 1;
if (left.dot(right) !== 80.5) throw Error('field shape change');
var effects = 0;
Object.defineProperty(right, 'x', {get: function () { effects++; return 7; }});
if (left.dot(right) !== 80.5 || effects !== 1) throw Error('field accessor replay');
left.z = {valueOf: function () { effects++; return 5; }};
if (left.dot(right) !== 80.5 || effects !== 3) throw Error('field coercion replay');
// Forward joins must preserve an entry value when only one arm overwrites it.
function branchRegion(a, b) {
  var x = a;
  if (b > 0) x = a * 2;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  x = x * 1.001 + a;
  return x;
}
function branchReference(a, b) {
  var x = b > 0 ? a * 2 : a;
  for (var i = 0; i < 3; i++) x = x * 1.001 + a;
  return x;
}
for (var i = 0; i < 1000; i++) {
  if (!Object.is(branchRegion(i, i & 1), branchReference(i, i & 1))) throw Error('region join');
}
print('Function SSA fields: PASS');
