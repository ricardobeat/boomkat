function eq(a, b, label) {
    if (a !== b) throw new Error(label + ': ' + a + ' !== ' + b);
}
let total = 0;
for (let i = 0; i < 1000; i++) total += i;
eq(total, 499500, 'numeric lexical sum');
function make(initial) {
    let value = initial;
    return function (next) { value = next; return value; };
}
var first = make(0);
var second = make(100);
for (var i = 0; i < 100; i++) {
    eq(first(i), i, 'first owner');
    eq(second(100 + i), 100 + i, 'second owner');
}
eq(first('string value'), 'string value', 'number to string');
eq(first(3), 3, 'string to number');
var obj = { n: 9 };
eq(first(obj), obj, 'number to object');
eq(first(4), 4, 'object to number');
eq(first(1n), 1n, 'number to bigint');
eq(first(5), 5, 'bigint to number');
const fixed = 2;
function setFixed() { fixed = 3; }
for (var j = 0; j < 2; j++) {
    var caught = false;
    try { setFixed(); } catch (e) { caught = e instanceof TypeError; }
    eq(caught, true, 'const rejects store');
}
var tdz = false;
try { before = 1; let before; } catch (e) { tdz = e instanceof ReferenceError; }
eq(tdz, true, 'TDZ rejects store');
let changing = 0;
function changeDuringRhs(next) { changing = next(); return changing; }
for (var r = 0; r < 20; r++) eq(changeDuringRhs(function () { return r; }), r, 'warm numeric store');
eq(changeDuringRhs(function () { changing = 'heap value'; return 31; }), 31, 'RHS changes binding type');
var holder = { value: 1 };
with (holder) { value += 2; }
eq(holder.value, 3, 'with store');
var setters = 0;
var accessor = { get value() { return 4; }, set value(x) { setters += x; } };
with (accessor) { value += 2; }
eq(setters, 6, 'with setter');
print('PASS threaded snapshot stores');
