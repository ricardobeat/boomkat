// Functions with thousands of declarations: the compiler finds a binding by
// name or register through an index, and an environment that large has a
// dictionary shape whose flags are edited without copying it.
function assert(value, message) { if (!value) throw new Error(message); }
function seq(n, each, sep) { var parts = []; for (var i = 0; i < n; i++) parts.push(each(i)); return parts.join(sep || '\n'); }
var N = 3000, SUM = N * (N - 1) / 2;

var f = new Function(seq(N, i => `let v${i} = ${i};`) + 'var s = 0;' + seq(N, i => `s += v${i};`) + 'return s;');
assert(f() === SUM, 'lets');

f = new Function(seq(N, i => `const c${i} = ${i};`) + 'try { c7 = 1; } catch (e) { return e instanceof TypeError && c7 + c2999; }');
assert(f() === 3006, 'consts stay constant');

f = new Function('p0', 'p1', seq(N, i => `var v${i} = ${i};`) + 'var p1; var p0 = p0 + 1; return p0 + p1 + v2999;');
assert(f(1, 2) === 3003, 'vars beside parameters');

f = new Function(seq(N, i => `var v${i} = ${i}; var g${i} = function () { return v${i}; };`) + 'var s = 0;' + seq(N, i => `s += g${i}();`) + 'return s;');
assert(f() === SUM, 'closures over vars');

f = new Function('var fs = [];' + seq(N, i => `for (let i = 0; i < 2; i++) { fs.push(() => i + ${i}); }`) + 'var s = 0; for (var k = 0; k < fs.length; k++) s += fs[k](); return s;');
assert(f() === 2 * SUM + N, 'closures over loop bindings of one name');

f = new Function('var s = 0;' + seq(N, i => `{ let a = ${i}; s += a; }`) + 'return s;');
assert(f() === SUM, 'blocks with a let');

f = new Function('var s = 0;' + seq(N, i => `try { throw ${i}; } catch (e) { var e = e + 1; s += e; }`) + 'return s;');
assert(f() === SUM + N, 'var over a catch parameter');

f = new Function('{' + seq(N, i => `function f${i}() { return ${i}; }`) + '} return f0() + f2999() + typeof f1500;');
assert(f() === '2999function', 'block functions reach the function scope');

f = new Function('p', '{ function p() {} } { function q() {} let r; { function r() {} } } return [typeof p, typeof q, typeof r].join();');
assert(f(1) === 'number,function,undefined', 'block functions a parameter or a let keeps out');

f = new Function(seq(N, i => `var v${i} = ${i};`) + 'var s = 0;'
    + seq(N, i => `if (v1) { function g${i}() { return v${i}; } } for (const v${i} of [1, 2]) { s += v${i}; } switch (1) { case 1: let v${i} = 5; s += v${i}; }`)
    + 'return s + g0() + g2999() + v2999;');
assert(f() === 8 * N + 2 * 2999, 'scopes that shadow a var of a large function');

// One closure reads every local of its function, another writes them, through a nested level too.
f = (0, eval)('(function () {' + seq(N, i => `var v${i} = ${i};`)
    + 'function sum() { return ' + seq(N, i => `v${i}`, '+') + '; }'
    + 'function bump() {' + seq(N, i => `v${i}++;`) + '}'
    + 'function deep() { return function () { return ' + seq(N, i => `v${i}`, '+') + ' + typeof unbound; }; }'
    + 'var before = sum(); bump(); return [before, sum(), deep()(), v0, v2999]; })');
var caps = f();
assert(caps[0] === SUM && caps[1] === SUM + N && caps[2] === (SUM + N) + 'undefined' && caps[3] === 1 && caps[4] === N,
    'closures over every local of a large function');

f = new Function(seq(N, i => `class C${i} { m() { return ${i}; } }`) + 'return new C0().m() + new C2999().m();');
assert(f() === 2999, 'classes');

f = new Function('return [' + seq(N, i => `[${i + 70000}, ${i + 70000}, 2]`, ',') + '];');
var rows = f();
assert(rows.length === N && rows[N - 1][0] === 72999 && rows[N - 1][2] === 2 && rows[0].length === 3, 'arrays of repeated numbers');

var o = {};
for (var i = 0; i < 200; i++) {
    o['k' + i] = i;
    if (i % 7 === 0) Object.defineProperty(o, 'k' + i, { writable: false });
}
function read(x) { return x.k14; }
for (var i = 0; i < 100; i++) assert(read(o) === 14, 'data property');
Object.defineProperty(o, 'k14', { get: function () { return -14; }, configurable: true });
assert(read(o) === -14, 'a cached read sees the accessor');
o.k7 = 0; o.k8 = 80;
assert(o.k7 === 7 && o.k8 === 80, 'read-only flags hold');
print('large scopes: OK');
