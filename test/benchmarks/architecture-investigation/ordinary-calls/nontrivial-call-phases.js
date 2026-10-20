// Measure the overhead beyond the empty/identity/add2 direct-call shortcuts.
var N = 1000000;
function arithmeticRun() {
    var sum = 0;
    for (var i = 0; i < N; i++) {
        var a = i + 2;
        var b = a * 3;
        sum += b - 1;
    }
    return sum;
}

function work(value) {
    var first = value + 2;
    var second = first * 3;
    return second - 1;
}
function callRun() {
    var sum = 0;
    for (var j = 0; j < N; j++) sum += work(j);
    return sum;
}

function shallow(depth, value) {
    if (depth <= 0) return value;
    return shallow(depth - 1, value + 1) + 2;
}
function recursionRun() {
    var sum = 0;
    for (var k = 0; k < 200000; k++) sum += shallow(4, 0);
    return sum;
}

var start = Date.now();
var arithmeticSum = arithmeticRun();
print('PHASE arithmetic ' + (Date.now() - start));
start = Date.now();
var callSum = callRun();
print('PHASE nontrivial-call ' + (Date.now() - start));
start = Date.now();
var recursiveSum = recursionRun();
print('PHASE shallow-recursion ' + (Date.now() - start));
if (arithmeticSum !== callSum || recursiveSum !== 2400000) throw new Error('call phase checksum');
