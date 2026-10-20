var N = 1000000;
var pair = [1, 2];

function patterned([a, b]) { return a + b; }
function indexed(p) { return p[0] + p[1]; }
function scalar(a, b) { return a + b; }

function patternReused(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += patterned(pair);
    return sum;
}

function indexedReused(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += indexed(pair);
    return sum;
}

function scalarReused(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += scalar(1, 2);
    return sum;
}

function patternAllocated(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += patterned([i, 1]);
    return sum;
}

function indexedAllocated(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += indexed([i, 1]);
    return sum;
}

function measure(name, fn, expected) {
    var start = Date.now();
    var result = fn(N);
    print("PHASE " + name + " " + (Date.now() - start));
    if (result !== expected) throw new Error(name + " checksum: " + result);
}

measure("patternReused", patternReused, 3000000);
measure("indexedReused", indexedReused, 3000000);
measure("scalarReused", scalarReused, 3000000);
measure("patternAllocated", patternAllocated, 500000500000);
measure("indexedAllocated", indexedAllocated, 500000500000);
