var N = 1000000;
var input = [1, 2];

function destructured(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        var [first, second] = input;
        sum += first + second;
    }
    return sum;
}

function indexed(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum += input[0] + input[1];
    return sum;
}

var expected = N * 3;
var start = Date.now();
var destructuredResult = destructured(N);
print('PHASE reused-array-destructure ' + (Date.now() - start));
start = Date.now();
var indexedResult = indexed(N);
print('PHASE reused-array-index ' + (Date.now() - start));
if (destructuredResult !== expected || indexedResult !== expected) {
    throw new Error('destructuring iterator cost checksum');
}
