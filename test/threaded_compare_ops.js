// Threaded LT/LE/GT/GE, LNOT, UNM and (strict) equality on mixed types.
//
// These ops used to run only on the switch. Their threaded handlers decide
// equality without string or BigInt contents and relations only on numbers;
// every other pair must still reach the switch. Expected values are from node.

var o = {};
var vals = [0, -0, 1, -1, 1.5, NaN, 2147483648, "", "a", "ab".slice(1), "1", null, undefined, true, false, o, o, {}, Symbol.iterator, 1n, 1n];
function row(a, b) {
    var r = '';
    // Three rounds so the comparisons run from the threaded handlers too.
    for (var k = 0; k < 3; k++) {
        r = (a === b ? 1 : 0) + '' + (a !== b ? 1 : 0) + (a == b ? 1 : 0) + (a != b ? 1 : 0);
        if (a === b) r += 's';
        if (a !== b) r += 'n';
        if (typeof a == 'number' && typeof b == 'number') r += (a < b ? 1 : 0) + '' + (a <= b ? 1 : 0) + (a > b ? 1 : 0) + (a >= b ? 1 : 0);
    }
    return r;
}
function unary(a) {
    var m = typeof a == 'number' ? -a : 'x';
    return (Object.is(m, -0) ? '-0' : String(m)) + (!a ? 'T' : 'F');
}
function table() {
    var out = [];
    for (var i = 0; i < vals.length; i++) {
        for (var j = 0; j < vals.length; j++) out.push(row(vals[i], vals[j]));
        out.push(unary(vals[i]));
    }
    return out.join(',');
}
var expected = '1010s0101,1010s0101,0101n1100,0101n0011,0101n1100,0101n0000,0101n1100,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,-0T,1010s0101,1010s0101,0101n1100,0101n0011,0101n1100,0101n0000,0101n1100,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0T,0101n0011,0101n0011,1010s0101,0101n0011,0101n1100,0101n0000,0101n1100,0101n,0101n,0101n,0110n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0110n,0110n,-1F,0101n1100,0101n1100,0101n1100,1010s0101,0101n1100,0101n0000,0101n1100,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1F,0101n0011,0101n0011,0101n0011,0101n0011,1010s0101,0101n0000,0101n1100,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,-1.5F,0101n0000,0101n0000,0101n0000,0101n0000,0101n0000,0101n0000,0101n0000,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,NaNT,0101n0011,0101n0011,0101n0011,0101n0011,0101n0011,0101n0000,1010s0101,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,-2147483648F,0110n,0110n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,xT,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,xF,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,xF,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0110n,0110n,xF,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,xT,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,1010s,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,xT,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,1010s,0101n,0101n,0101n,0101n,0101n,0110n,0110n,xF,0110n,0110n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0101n,0101n,0101n,0101n,xT,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,1010s,0101n,0101n,0101n,0101n,xF,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,1010s,0101n,0101n,0101n,0101n,xF,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,0101n,xF,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,1010s,0101n,0101n,xF,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,1010s,1010s,xF,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,0101n,0101n,0110n,0101n,0101n,0110n,0101n,0101n,0101n,0101n,0101n,1010s,1010s,xF';
var got = table();
if (got !== expected) {
    var g = got.split(','), e = expected.split(',');
    for (var i = 0; i < e.length; i++) if (g[i] !== e[i]) print('FAIL at ' + i + ': got ' + g[i] + ', want ' + e[i]);
    throw new Error('FAIL');
}
print('threaded_compare_ops: passed');
