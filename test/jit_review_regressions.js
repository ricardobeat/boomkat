// Regressions for operand roles, dense undefined pushes and inherited IC arms.
function assert(value, message) { if (!value) throw new Error(message); }
function readAlias(o) { var p = o; return p.a + p.b; }
for (var i = 0; i < 300; i++) assert(readAlias({a: 1, b: 2}) === 3, 'property constant changed');

function append(a, v) { var n = a.push(v); return n + 0; }
for (var i = 0; i < 500; i++) {
    var a = [1, 2, 3];
    a.pop();
    append(a, i);
}
var a = [1, 2, 3];
a.pop();
assert(append(a, undefined) === 3, 'push length');
assert(Object.prototype.hasOwnProperty.call(a, '2'), 'undefined must be present');
assert(2 in a, 'undefined index must exist');
assert(Object.keys(a).length === 3, 'undefined index must enumerate');
var visits = 0;
a.forEach(function () { visits++; });
assert(visits === 3, 'undefined index must be visited');

var proto = {length: 99};
var one = Object.create(proto);
var two = Object.create(proto); two.b = 2;
var arr = [1, 2, 3]; Object.setPrototypeOf(arr, proto);
function lengthOf(x) { var n = x.length; n = n * 2; n = n + 3; n = n * 2; n = n - 6; return n / 4; }
for (var i = 0; i < 500; i++) {
    assert(lengthOf(one) === 99 && lengthOf(two) === 99, 'inherited length');
}
assert(lengthOf(arr) === 3, 'array own length');
print('ok');
