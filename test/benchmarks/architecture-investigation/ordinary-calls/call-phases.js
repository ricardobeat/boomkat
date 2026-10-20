// Phase-separated function-call benchmark. Each result is checked so a fast
// path cannot win by skipping the call's observable work.
var N = 2000000;
function empty() {}
function identity(value) { return value; }
function add2(left, right) { return left + right; }

function measure(name, run) {
    var start = Date.now();
    var result = run();
    print('PHASE ' + name + ' ' + (Date.now() - start));
    return result;
}

var emptyResult = measure('empty', function () {
    for (var i = 0; i < N; i++) empty();
    return 1;
});
var identityResult = measure('identity', function () {
    var sum = 0;
    for (var i = 0; i < N; i++) sum += identity(42);
    return sum;
});
var addResult = measure('add2', function () {
    var sum = 0;
    for (var i = 0; i < N; i++) sum += add2(3, 7);
    return sum;
});
if (emptyResult !== 1 || identityResult !== N * 42 || addResult !== N * 10) {
    throw new Error('call benchmark checksum');
}
