function check(value, label) {if (!value) throw new Error(label);}
function* append(n) {
    var value = 'prefix:' + 'x'.repeat(80);
    for (var i = 0; i < n; i++) {
        value += 'tail';
        yield i;
    }
    return value;
}
var it = append(400), r, count = 0;
while (!(r = it.next()).done) count++;
check(count === 400 && r.value === 'prefix:' + 'x'.repeat(80) + 'tail'.repeat(400), 'accumulator');
function* prefixes() {
    var s = 'x'.repeat(90);
    yield s;
    s += 'a';
    yield s;
    s += 'b';
    return s;
}
var p = prefixes();
var one = p.next().value, two = p.next.call(p).value, three = p.next.apply(p, []).value;
check(one === 'x'.repeat(90) && two === one + 'a' && three === two + 'b', 'retained prefixes');
function* abrupt() {
    var s = 'held:' + 's'.repeat(100);
    try {
        try {yield s;} catch (e) {s += e.message; yield s;}
    } finally {yield s + ':finally';}
    return s;
}
var a = abrupt(), first = a.next().value;
check(a.throw(new Error(':caught')).value === first + ':caught', 'throw restore');
check(a.return('returned').value === first + ':caught:finally', 'finally restore');
check(a.next().value === 'returned' && a.next().done, 'return restore');
function* delegate() {var s = 'delegate:' + 'z'.repeat(80);yield* prefixes();return s;}
var d = delegate(), next = d.next.bind(d);
check(next().value === one && next().value === two, 'delegation');
check(next().value === 'delegate:' + 'z'.repeat(80), 'delegate register');
function* nested() {
    var owner = {text: 'object:' + 'q'.repeat(90)};
    yield owner;
    [1].forEach(function() {
        var inner = append(10);
        while (!inner.next().done) {}
    });
    yield owner.text;
}
var n = nested(), object = n.next().value;
check(n.next().value === object.text && n.next().done, 'nested native roots');
function* mapped(x) {var args = arguments;yield x;x = 'new:' + 'm'.repeat(80);yield args[0];}
var m = mapped('old');
check(m.next().value === 'old' && m.next().value === 'new:' + 'm'.repeat(80), 'mapped arguments');
print('generator register ownership PASS');
