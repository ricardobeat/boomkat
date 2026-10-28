// Keep more floating-point loop values live than the SSA register budget.
// Repeated calls exercise native entry, backedge copies and side exits.
function floatSpills(n, a) {
  var x0 = 0.5, x1 = 1.5, x2 = 2.5, x3 = 3.5, x4 = 4.5;
  var x5 = 5.5, x6 = 6.5, x7 = 7.5, x8 = 8.5, x9 = 9.5;
  for (var i = 0; i < n; i++) {
    x0 += a[i]; x1 += 0.25; x2 += 0.25; x3 += 0.25; x4 += 0.25;
    x5 += 0.25; x6 += 0.25; x7 += 0.25; x8 += 0.25; x9 += 0.25;
  }
  return x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8 + x9;
}
var values = new Float64Array(64);
for (var i = 0; i < values.length; i++) values[i] = i * 0.5;
for (var i = 0; i < 200; i++) {
  if (floatSpills(64, values) !== 1202) throw Error('float loop spills');
}
if (floatSpills(0, values) !== 50) throw Error('empty float loop');
values[20] = NaN;
if (!Number.isNaN(floatSpills(64, values))) throw Error('float spill NaN');
print('SSA float spills: PASS');
