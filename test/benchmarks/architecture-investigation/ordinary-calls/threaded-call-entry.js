// Separate method entry from property work: each call body performs the same
// arithmetic as the in-loop control and touches no receiver properties.
var N = 1000000;

class CallTarget {
    transform(a, b) {
        var first = a + b;
        var second = first * 2;
        return second + 1;
    }

    self() { return this; }
}

var target = new CallTarget();
var directTransform = target.transform;

function arithmeticRun() {
    var sum = 0;
    for (var i = 0; i < N; i++) {
        var first = i + 1;
        var second = first * 2;
        sum += second + 1;
    }
    return sum;
}

function directCallRun() {
    var sum = 0;
    for (var i = 0; i < N; i++) sum += directTransform(i, 1);
    return sum;
}

function methodCallRun() {
    var sum = 0;
    for (var i = 0; i < N; i++) sum += target.transform(i, 1);
    return sum;
}

function selfReturnRun() {
    var result;
    for (var i = 0; i < N; i++) result = target.self();
    return result;
}

var start = Date.now();
var arithmeticSum = arithmeticRun();
print('PHASE arithmetic ' + (Date.now() - start));
start = Date.now();
var directSum = directCallRun();
print('PHASE direct-call ' + (Date.now() - start));
start = Date.now();
var methodSum = methodCallRun();
print('PHASE method-call ' + (Date.now() - start));
start = Date.now();
var selfResult = selfReturnRun();
print('PHASE return-this ' + (Date.now() - start));

if (arithmeticSum !== 1000002000000 || directSum !== arithmeticSum || methodSum !== arithmeticSum) {
    throw new Error('call-entry checksum mismatch');
}
if (selfResult !== target) throw new Error('return-this receiver mismatch');
