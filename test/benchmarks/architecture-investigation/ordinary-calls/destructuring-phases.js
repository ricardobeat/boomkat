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

function paramPattern({ x, y }, [a, b]) { return x + y + a + b; }
function params(n) {
    let s = 0;
    for (let i = 0; i < n; i++) { s += paramPattern({ x: i, y: 1 }, [i, 1]); }
    return s;
}

function measure(name, fn, n, expected) {
    var start = Date.now();
    var result = fn(n);
    print('PHASE ' + name + ' ' + (Date.now() - start));
    if (result !== expected) throw new Error(name + ' checksum: ' + result);
}

measure('arrayPattern', arrayPattern, N, 250000000000);
measure('objectPattern', objectPattern, N, 250000000000);
measure('withDefaults', withDefaults, N, 125000750000);
measure('restElement', restElement, N / 2, 31250375000);
measure('params', params, N / 2, 62500250000);
