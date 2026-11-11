// The iterator protocol's key loads ("iterator", "next", "done", "value", the
// dispose helpers) must reach a constant-pool index above 255.
function assert(ok, what) { if (!ok) throw new Error('FAIL: ' + what); }
var pad = 'var o = {};';
for (var i = 0; i < 300; i++) pad += `o.k${i} = 1;`;
function iterable() {
    var i = 0;
    return { [Symbol.iterator]() { return this; }, next() { return { done: i > 2, value: i++ }; } };
}
assert(new Function('it', pad + 'var s = 0; for (var v of it) s += v; return s;')(iterable()) === 3, 'for-of');
assert(new Function('it', pad + 'var [a, b, ...c] = it; return a + b + c[0];')(iterable()) === 3, 'array pattern');
assert(new Function('it', pad + 'var a, b; [a, [b]] = [1, it]; return a + b;')(iterable()) === 1, 'nested assignment pattern');
assert(new Function('it', pad + 'return [...it].length;')(iterable()) === 3, 'spread');
assert([...new Function('it', 'return function* () {' + pad + 'yield* it; }')(iterable())()].length === 3, 'yield*');
assert(new Function(pad + 'var n = 0; { using r = { [Symbol.dispose]() { n++; } }; } return n;')() === 1, 'using');
print('iterator keys past 255 constants: OK');
