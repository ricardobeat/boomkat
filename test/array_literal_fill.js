// A short literal without holes or spreads is built in one step from its
// element registers. Its elements must behave as INITELEM's do: counted
// strings, `undefined` as a present element, and an ordinary array afterwards.
function check(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ': expected ' + expected + ', got ' + actual);
}
function shape(a) {
    var s = a.length + ':';
    for (var i = 0; i < a.length; i++) s += (i in a ? String(a[i]) : '_') + ',';
    return s;
}
function build(i) {
    var s = 'k' + i;
    return [s, s + 'x', i, undefined, null, s];
}
var kept = [];
for (var n = 0; n < 3000; n++) {
    var a = build(n);
    check(shape(a), '6:k' + n + ',k' + n + 'x,' + n + ',undefined,null,k' + n + ',', 'elements ' + n);
    if (n % 100 === 0) kept.push(a);
    var junk = [n + 'a', n + 'b', n + 'c'];
    check(junk[2], n + 'c', 'string element');
}
for (var k = 0; k < kept.length; k++) check(kept[k][1], 'k' + (k * 100) + 'x', 'kept ' + k);

// A packed literal turns ordinary when a hole appears below its length.
var p = [undefined, 1, undefined];
check(shape(p), '3:undefined,1,undefined,', 'packed');
p.length = 5;
p[4] = 2;
check(shape(p), '5:undefined,1,undefined,_,2,', 'packed grown');
delete p[0];
check(shape(p), '5:_,1,undefined,_,2,', 'packed delete');

// Growth, pops and the largest inline literal.
var g = ['a', 'b'];
g.push('c'); g.unshift('z');
check(g.join(''), 'zabc', 'push and unshift');
var w = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 'x' + g.length];
check(w.length + w[15], '16x4', 'sixteen');
var x = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 'y' + g.length];
check(x.length + x[16], '17y4', 'seventeen');

// Evaluation order and an element that throws.
var log = '';
function v(t) { log += t; return t; }
var o = [v('a'), v('b'), v('c')];
check(log + o.join(''), 'abcabc', 'order');
var threw = false;
try { [v('d'), (function () { throw 1; })(), v('e')]; } catch (e) { threw = e === 1; }
check(threw && log === 'abcd', true, 'throw');
print('ok');
