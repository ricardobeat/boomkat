// Destructuring. Array patterns run the iterator protocol; object patterns are
// property reads. Defaults and rest elements add their own steps.
var N = 500000;

function arrayPattern(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { const [a, b] = [i, i + 1]; s += a + b; }
    return s;
}

function objectPattern(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { const { x, y } = { x: i, y: i + 1 }; s += x + y; }
    return s;
}

function withDefaults(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { const { a = 1, b = 2 } = { a: i }; s += a + b; }
    return s;
}

function restElement(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { const [first, ...rest] = [i, i + 1, i + 2]; s += first + rest.length; }
    return s;
}

// Destructured parameters, which bind on every call.
function paramPattern({ x, y }, [a, b]) { return x + y + a + b; }
function params(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += paramPattern({ x: i, y: 1 }, [i, 1]); }
    return s;
}

var r = 0;
r += arrayPattern(N);
r += objectPattern(N);
r += withDefaults(N);
r += restElement(N / 2);
r += params(N / 2);
if (r === 0) throw new Error("optimized away");
