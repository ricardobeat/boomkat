var checks = 0;
function check(v) { if (!v) throw new Error('literal check ' + checks); checks++; }
function make(i) {
    var label = 'value-' + i;
    return { a: i, label: label, child: { value: i + 1 }, missing: undefined,
             flag: true, text: label, tail: null };
}
var held = [];
for (var i = 0; i < 20000; i++) {
    var o = make(i);
    check(o.a === i && o.child.value === i + 1 && o.label === o.text);
    if (i % 1000 === 0) held.push(o);
}
for (var i = 0; i < held.length; i++) {
    var o = held[i];
    check(o.label === 'value-' + i * 1000);
    check(Object.keys(o).join(',') === 'a,label,child,missing,flag,text,tail');
    check(o.hasOwnProperty('missing'));
    var d = Object.getOwnPropertyDescriptor(o, 'a');
    check(d.writable && d.enumerable && d.configurable);
}
var first = make(1), second = make(2);
delete first.a;
Object.defineProperty(first, 'label', { get: function () { return 42; } });
first.extra = 3;
Object.freeze(first);
check(second.a === 2 && second.label === 'value-2' && !second.hasOwnProperty('extra'));
var order = [];
function value(n) { order.push(n); if (n === 3) throw 3; return n; }
try { var unused = { a: value(1), b: value(2), c: value(3), d: value(4) }; } catch (e) { check(e === 3); }
check(order.join(',') === '1,2,3');
Object.defineProperty(Object.prototype, 'literal_guard', { set: function () { throw 1; }, configurable: true });
var guarded = { literal_guard: 7 };
delete Object.prototype.literal_guard;
check(guarded.literal_guard === 7);
var short = 9;
check(({ short: 1, short: 2 }).short === 2);
check(({ short }).short === 9);
check(({ ['x']: 4, y: 5 }).x === 4);
check(({ ...{ x: 3 }, y: 4 }).x === 3);
check(Object.getPrototypeOf({ __proto__: null, x: 1 }) === null);
check(({ get x() { return 4; }, y: 5 }).x === 4);
check(({ x() { return 4; }, y: 5 }).x() === 4);
check(Object.keys({ '2': 2, a: 1, '1': 1 }).join(',') === '1,2,a');
function* suspended() { return { a: 'before', b: yield 7, c: { x: 9 } }; }
var g = suspended();
check(g.next().value === 7);
for (var i = 0; i < 20000; i++) make(i);
var result = g.next('after').value;
check(result.a === 'before' && result.b === 'after' && result.c.x === 9);
for (var i = 0; i < 100; i++) {
    var dynamic = eval('({first: ' + i + ', second: "dynamic", third: {value: 7}})');
    check(dynamic.first === i && dynamic.second === 'dynamic' && dynamic.third.value === 7);
}
print('fixed shape literals: ' + checks);
