// Spread and rest. Array spread runs the iterator protocol over the source;
// object spread copies own enumerable properties; rest parameters build an
// array on every call.
var N = 200000;

const src = [];
for (let i = 0; i < 16; i++) { src.push(i); }
const obj = { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 };

function arraySpread(n) {
    let len = 0;
    for (let i = 0; i < n; i++) { const a = [...src, i]; len += a.length; }
    return len;
}

function objectSpread(n) {
    let len = 0;
    for (let i = 0; i < n; i++) { const o = { ...obj, i }; len += o.a; }
    return len;
}

function restParams(...args) { return args.length; }
function callWithRest(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += restParams(1, 2, 3, 4, 5); }
    return s;
}

function spreadCall(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += Math.max(...src); }
    return s;
}

var r = 0;
r += arraySpread(N);
r += objectSpread(N);
r += callWithRest(N * 2);
r += spreadCall(N / 2);
if (r === 0) throw new Error("optimized away");
