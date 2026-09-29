var N = 400000;
function restParams(...args) { return args.length; }
function callWithRest(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        sum += restParams(1, 2, 3, 4, 5);
    }
    return sum;
}

var start = Date.now();
var result = callWithRest(N);
print('PHASE rest-parameter ' + (Date.now() - start));
if (result !== N * 5) throw new Error('rest parameter checksum: ' + result);
