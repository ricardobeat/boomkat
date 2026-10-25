// Shapes made by delete are private to one object and die with it, so their
// ids are reused. Property reads at each site must keep resolving the right
// slot as new layouts take over those ids.
var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print('FAIL: ' + m); } }

function mk(i) {
  var o = { a: i, b: i * 2, c: i * 3, d: i * 4 };
  if (i % 3 == 0) delete o.b;
  if (i % 5 == 0) { delete o.a; o.e = -i; }
  return o;
}
function rd(o) { return (o.a | 0) + (o.b | 0) + (o.c | 0) + (o.d | 0) + (o.e | 0); }
var P = { m: function () { return this.c | 0; } };
function proto_rd(o) { return o.m(); }

var sum = 0, expect = 0;
for (var i = 0; i < 60000; i++) {
  sum += rd(mk(i));
  var a = i % 5 == 0 ? 0 : i, b = i % 3 == 0 ? 0 : i * 2, e = i % 5 == 0 ? -i : 0;
  expect += a + b + i * 3 + i * 4 + e;
  if (i % 7 == 0) {
    var q = Object.create(P); q.c = i; delete q.c; q.c = i + 1;
    sum += proto_rd(q); expect += i + 1;
  }
  if (i % 11 == 0) {
    var big = {};
    for (var k = 0; k < 70; k++) big['k' + k] = k;
    delete big.k3;
    sum += big.k69; expect += 69;
  }
}
assert(sum === expect, 'reads through recycled shape ids (' + sum + ' vs ' + expect + ')');

print('shape_id_recycle_ic: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
