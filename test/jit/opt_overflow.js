// Optimizing tier numeric edges: int32 overflow, -0, NaN, shifts and USHR, in
// loops and straight-line code. Run under --opt-always and compared by value.
var fails = 0;
function eq(a, b, msg) {
    if (Object.is(a, b) || (a !== a && b !== b)) return;
    fails++;
    print('FAIL: ' + msg + ' (got ' + a + ', want ' + b + ')');
}

function add(a, b) { return a + b; }
function sub(a, b) { return a - b; }
function mul(a, b) { return a * b; }
function shl(a, b) { return a << b; }
function sar(a, b) { return a >> b; }
function ushr(a, b) { return a >>> b; }
function toint(a) { return a | 0; }
function neg(a) { return -a; }

for (var i = 0; i < 3; i++) {
    eq(add(2147483647, 1), 2147483648, 'add overflow');
    eq(add(-2147483648, -1), -2147483649, 'add underflow');
    eq(sub(-2147483648, 1), -2147483649, 'sub underflow');
    eq(sub(2147483647, -1), 2147483648, 'sub overflow');
    eq(mul(65536, 65536), 4294967296, 'mul overflow');
    eq(mul(0, -5), -0, 'mul negative zero');
    eq(mul(-5, 0), -0, 'mul negative zero 2');
    eq(mul(0, 5), 0, 'mul zero');
    eq(mul(46341, 46341), 2147488281, 'mul just over');
    eq(shl(1, 31), -2147483648, 'shl sign');
    eq(shl(1, 32), 1, 'shl count mask');
    eq(shl(3, 33), 6, 'shl count mask 2');
    eq(sar(-8, 1), -4, 'sar');
    eq(sar(-8, 33), -4, 'sar mask');
    eq(ushr(-1, 0), 4294967295, 'ushr above int32');
    eq(ushr(-1, 1), 2147483647, 'ushr max');
    eq(ushr(-8, 28), 15, 'ushr small');
    eq(ushr(5, 0), 5, 'ushr plain');
    eq(toint(4294967296.5), 0, 'toint modulo');
    eq(toint(-2147483649.9), 2147483647, 'toint wrap');
    eq(toint(NaN), 0, 'toint NaN');
    eq(toint(Infinity), 0, 'toint inf');
    eq(toint(1e19), 1e19 % 4294967296 | 0, 'toint big');
    eq(toint(2.9), 2, 'toint trunc');
    eq(toint(-2.9), -2, 'toint trunc neg');
    eq(neg(0), -0, 'neg zero');
    eq(add(0.5, 0.25), 0.75, 'add float');
    eq(add(1, NaN), NaN, 'add NaN');
    eq(sub(0, 0), 0, 'sub zero');
}

function loop(n) {
    var s = 0;
    for (var i = 0; i < n; i++) s = s + i * i;
    return s;
}
function loopf(n) {
    var s = 0.5;
    for (var i = 0; i < n; i++) s = s + i / 2;
    return s;
}
function bits(n) {
    var h = 0;
    for (var i = 0; i < n; i++) h = ((h << 5) - h + i) | 0;
    return h;
}
function xorshift(n) {
    var x = 123456789;
    for (var i = 0; i < n; i++) { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; }
    return x;
}
for (var k = 0; k < 3; k++) {
    eq(loop(10), 285, 'loop');
    eq(loop(3000), 8995500500, 'loop overflow');
    eq(loopf(10), 23, 'loopf');
    eq(bits(100), 58926130, 'bits');
    eq(xorshift(10), -920365318, 'xorshift');
}
if (fails) throw new Error(fails + ' failures');
print('opt_overflow ok');
