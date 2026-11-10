// String.fromCharCode of one integer below 256 answers from the cache of one-unit strings; every
// other argument, and every other count, still converts and builds as the specification says.
function assert(value, message) { if (!value) throw new Error(message); }
var f = String.fromCharCode;
for (var u = 0; u < 256; u++) {
    var s = f(u);
    assert(s.length === 1 && s.charCodeAt(0) === u, 'unit ' + u);
    assert(s === String.fromCharCode(u), 'same string ' + u);
    assert(s === '\u0000'.replace('\u0000', s), 'interned equal ' + u);
}
assert(f(-1) === '￿', 'negative wraps');
assert(f(65536 + 65) === 'A', 'above 0xffff wraps');
assert(f(-65536 + 233) === 'é', 'negative wraps into Latin-1');
assert(f(256) === 'Ā', 'first wide unit');
assert(f(0x20ac) === '€', 'wide unit');
assert(f(65.9) === 'A', 'fraction truncates');
assert(f('66') === 'B', 'string converts');
assert(f(NaN) === '\u0000' && f(Infinity) === '\u0000', 'non-finite is zero');
assert(f() === '', 'no arguments');
assert(f(72, 105) === 'Hi', 'two arguments');
assert(f(233, 0x20ac) === 'é€', 'mixed widths');
var calls = 0;
assert(f({ valueOf: function () { calls++; return 67; } }) === 'C' && calls === 1, 'valueOf once');
var threw = false;
try { f(Symbol('x')); } catch (e) { threw = e instanceof TypeError; }
assert(threw, 'symbol throws');
// Strings built from cached units compare and key like any other.
var o = {};
for (var u = 0; u < 256; u++) o[f(u)] = u;
for (var u = 0; u < 256; u++) assert(o[String.fromCharCode(u)] === u, 'key ' + u);
var joined = '';
for (var u = 0; u < 256; u++) joined += f(u);
assert(joined.length === 256 && joined.charCodeAt(200) === 200, 'concatenation');
print('ok');
