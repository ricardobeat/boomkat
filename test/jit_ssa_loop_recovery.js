// A nested stencil has observable array stores before an inner-loop poll or
// numeric guard. Retiring its native plan must preserve the completed prefix.
function stencilFactory(n, reference, lateGuard) {
    var rowSize = n + 2;
    var input = lateGuard ? 'b[p]*1' : 'b[p]';
    var body = 'for(var k=0;k<20;k++){' +
        'for(var j=1;j<=n;j++){' +
        'var p=j*rowSize,lo=(j-1)*rowSize,hi=(j+1)*rowSize;' +
        'var last=a[p];++p;' +
        'for(var i=1;i<=n;i++){' +
        'last=a[p]=(' + input + '+last+a[++p])*.25;}}}';
    // Direct eval keeps the reference on the ordinary VM path.
    return eval('(function stencil(a,b){' + (reference ? 'eval("");' : '') + body + '})');
}
for (var scenario = 0; scenario < 2; scenario++) {
    var n = 16, size = (n + 2) * (n + 2);
    var actual = stencilFactory(n, false, scenario === 1);
    var reference = stencilFactory(n, true, scenario === 1);
    for (var round = 0; round < 3; round++) {
        var a = [], expected = [], input = [];
        for (var i = 0; i < size; i++) {
            a[i] = expected[i] = ((i * 19 + round * 13) % 107) / 107;
            input[i] = ((i * 31 + round * 3) % 101) / 101;
        }
        // The first round warms a numeric cyclic plan. A later round must
        // retire it at this read after preserving every completed store.
        if (scenario === 1 && round > 0) input[12 * (n + 2) + 8] = '0.5';
        actual(a, input);
        reference(expected, input);
        for (var i = 0; i < size; i++) {
            if (a[i] !== expected[i]) {
                throw new Error('cyclic recovery scenario=' + scenario + ' round=' + round + ' index=' + i);
            }
        }
    }
}
console.log('JIT cyclic loop recovery: PASS');
