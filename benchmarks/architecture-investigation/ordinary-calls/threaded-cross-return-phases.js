// Scale the arithmetic and ordinary-call controls so millisecond phase
// readings have enough resolution to compare threaded cross-function returns.
var N = 5000000;

function arithmeticRun() {
    var sum = 0;
    for (var i = 0; i < N; i++) {
        var first = i + 2;
        var second = first * 3;
        sum += second - 1;
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
    for (var i = 0; i < N; i++) sum += work(i);
    return sum;
}

var start = Date.now();
var arithmeticSum = arithmeticRun();
print('PHASE arithmetic ' + (Date.now() - start));
start = Date.now();
var callSum = callRun();
print('PHASE cross-function-call ' + (Date.now() - start));
if (arithmeticSum !== callSum) throw new Error('cross-return phase checksum');
