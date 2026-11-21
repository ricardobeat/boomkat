// Module bindings read from hot functions (GETVAR into the module environment), which the
// optimizing tier folds as constants under a watch: a const typed array, functions, a let that
// changes after the reader is optimized, and a function binding reassigned.
function assert(c, m) { if (!c) { throw new Error('FAIL: ' + m); } }

const table = new Float64Array([1.5, 2.5, 3.5, 4.5]);
const cfg = { scale: 2 };
let offset = 10;
let step = function (x) { return x + 1; };
function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

function read(i) { return clamp(table[i & 3] * cfg.scale + offset, 0, 1000) + step(i); }
function run(n) { let s = 0; for (let i = 0; i < n; i++) s += read(i); return s; }

function expect(n) {
    let s = 0;
    for (let i = 0; i < n; i++) s += Math.max(0, Math.min(1000, table[i & 3] * cfg.scale + offset)) + step(i);
    return s;
}

for (let r = 0; r < 4; r++) assert(run(50000) === expect(50000), 'warm run ' + r);
offset = 20;
assert(run(50000) === expect(50000), 'let changed after optimization');
step = function (x) { return x * 3; };
assert(run(50000) === expect(50000), 'function binding reassigned');
table[2] = 100;
cfg.scale = 7;
assert(run(50000) === expect(50000), 'contents of folded objects changed');
offset = 2000;
assert(run(1000) === expect(1000), 'clamped');
