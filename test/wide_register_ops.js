// A function with more than 256 registers encodes its high-numbered operands
// with a WIDE prefix. Moves, integer loads, arithmetic, comparisons and
// branches on those registers must match the narrow forms.
var pass = 0, fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) pass++;
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

var decls = [];
for (var i = 0; i < 300; i++) decls.push('v' + i + ' = ' + i);
var body = 'var ' + decls.join(', ') + ';\n' +
    'var n = 0, s = 0, bits = 0, flags = 0, str = "";\n' +
    'for (var k = 0; k < 2000; k++) {\n' +
    '    var t = v299 + k;\n' +
    '    var u = t - v150;\n' +
    '    bits = (bits ^ (u << 3)) | (k & 7);\n' +
    '    bits = bits >>> 1; bits = bits >> 0;\n' +
    '    if (t < 1000) n++;\n' +
    '    if (t >= 2000) s += 70000;\n' +
    '    if (k == 5 || k === 7) flags++;\n' +
    '    if (k != 3 && k !== 4) flags += 2;\n' +
    '    if ("a" + k == "a5") str = "five";\n' +
    '    s += u > 1 ? 1 : 0; s += u <= 1 ? 100 : 0;\n' +
    '}\n' +
    'var big = 1234567, neg = -40000, half = 0.5;\n' +
    'var sum = v298 + half, ovf = 0x3fffffff;\n' +
    'return [n, s, bits, flags, str, big, neg, sum, ovf + ovf + ovf].join(",");';
var f = new Function(body);
var expect = (function () {
    var n = 0, s = 0, bits = 0, flags = 0, str = "";
    for (var k = 0; k < 2000; k++) {
        var t = 299 + k, u = t - 150;
        bits = (bits ^ (u << 3)) | (k & 7);
        bits = bits >>> 1; bits = bits >> 0;
        if (t < 1000) n++;
        if (t >= 2000) s += 70000;
        if (k == 5 || k === 7) flags++;
        if (k != 3 && k !== 4) flags += 2;
        if ("a" + k == "a5") str = "five";
        s += u > 1 ? 1 : 0; s += u <= 1 ? 100 : 0;
    }
    return [n, s, bits, flags, str, 1234567, -40000, 298.5, 0x3fffffff * 3].join(",");
})();
for (var r = 0; r < 3; r++) eq(f(), expect, 'wide operands, run ' + r);

print('wide_register_ops: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
