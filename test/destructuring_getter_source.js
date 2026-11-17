// A getter read by an object pattern must not disturb the pattern's source.
//
// A getter run by GETPROP takes its frame from the result register up. A
// lexical binding's home register can sit below the register holding the
// source (or a parent group), so reading straight into it put the getter's
// frame over the source and the next property was read from undefined.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }
function eq(a, b, m) { ok(a === b, m + ' (got ' + a + ', want ' + b + ')'); }
function run(f, m) { try { f(); } catch (e) { fail++; print('FAIL: ' + m + ' threw ' + e); } }

const o = { x: 1, y: 2, get a() { return this.x; }, get b() { return this.y; } };

run(function () { const { a, b } = o; eq(a + b, 3, 'const'); }, 'const');
run(function () { let { b, a } = o; eq(a * 10 + b, 12, 'let'); }, 'let');
run(function () { var { a, b } = o; eq(a + b, 3, 'var'); }, 'var');
run(function () { let a, b; ({ a, b } = o); eq(a + b, 3, 'assignment'); }, 'assignment');
run(function () { const { a, x, b, y } = o; eq(a + x + b + y, 6, 'mixed'); }, 'mixed');
run(function () { const { a = 9, b = 9, z = 5 } = o; eq(a + b + z, 8, 'defaults'); }, 'defaults');
run(function () { const { p: { a, b } } = { p: o }; eq(a + b, 3, 'nested'); }, 'nested');
run(function () { const k = 'a'; const { [k]: a, b } = o; eq(a + b, 3, 'computed'); }, 'computed');

class Vec { constructor(x, y) { this.x = x; this.y = y; }
    get width() { return this.x; } get height() { return this.y; } }
class R { constructor() { this.v = new Vec(4, 5); } size() { return this.v; }
    area() { const { width, height } = this.size(); return width * height; } }
run(function () { const r = new R(); for (let i = 0; i < 200; i++) eq(r.area(), 20, 'method source'); },
    'method source');

const { a: ga, b: gb } = o;
eq(ga + gb, 3, 'script top level');

if (fail === 0) {
    print('PASS: getter in a destructuring source (' + pass + ' checks)');
} else {
    throw new Error(fail + ' of ' + (pass + fail) + ' checks failed');
}
