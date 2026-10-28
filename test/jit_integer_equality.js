function eq(a, b) { return a == b; }
function ne(a, b) { return a != b; }
var cases = [[0, 0, true], [-1, 1, false], [2147483648, 2147483648, true],
  [1, 1.5, false], [0, -0, true], [NaN, NaN, false],
  [1, '1', true], [null, undefined, true], [false, 0, true]];
for (var repeat = 0; repeat < 500; repeat++) {
  for (var i = 0; i < cases.length; i++) {
    var c = cases[i];
    if (eq(c[0], c[1]) !== c[2] || ne(c[0], c[1]) === c[2]) throw Error('equality ' + i);
  }
}
var calls = 0;
var object = {valueOf: function () { calls++; return 1; }};
if (!eq(object, 1) || ne(object, 1) || calls !== 2) throw Error('coercion');
print('Integer equality: PASS');
