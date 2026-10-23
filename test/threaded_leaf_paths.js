// Leaf paths of threaded handlers.
//
// GETCAP, GETVAR, typed array element access and the constant loads run as
// call-free handlers: the shadow-guarded capture walk, a variable cache rearm
// and a double typed store moved out of line, LDNULL/LDTRUE/LDFALSE gained
// handlers, and ToInt32 takes a direct path inside the int32 range. Expected
// values come from node.

var pass = 0;
var fail = 0;
function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print("FAIL: " + msg + "\n got:  " + actual + "\n want: " + expected); }
}

// Integer stores into every typed array class: low bits, clamping, and floats.
var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
             Int32Array, Uint32Array, Float32Array, Float64Array];
var ints = [0, 1, -1, 127, 128, 255, 256, -129, 32767, 32768, 65535, 65536,
            2147483647, -2147483648, 4294967295, 4294967296, 8589934593, -8589934593, 16777217];
var dbls = [1.5, -1.5, 2.5, 255.5, 254.5, -0.5, 2147483647.5, -2147483648.5, 2147483648.25,
            -2147483649.75, 4294967296.5, 1e20, -1e20, NaN, Infinity, -Infinity];
function fmt(v) { return Object.is(v, -0) ? '-0' : String(v); }
function stores(ta, vals) {
    for (var r = 0; r < 3; r++) for (var i = 0; i < vals.length; i++) ta[i] = vals[i];
    var out = [];
    for (var i = 0; i < vals.length; i++) out.push(fmt(ta[i]));
    return out.join(' ');
}
function typedRows() {
    var rows = [];
    for (var k = 0; k < kinds.length; k++) {
        rows.push(stores(new kinds[k](ints.length), ints));
        rows.push(stores(new kinds[k](dbls.length), dbls));
    }
    // Bitwise ops on doubles at the int32 edges.
    var b = [];
    for (var i = 0; i < dbls.length; i++) b.push(dbls[i] | 0, dbls[i] >>> 0, ~dbls[i]);
    rows.push(b.join(' '));
    return rows.join('\n');
}
// Constants overwrite registers holding strings; variable caches rearm per scope.
function consts(s) {
    var a = s + 'x', b = s + 'y', c = s + 'z';
    for (var i = 0; i < 3; i++) { a = null; b = true; c = false; }
    return String(a) + b + c;
}
function makeCounter(start) {
    var n = start;
    return function () { n = n + 1; return n; };
}
function scopes() {
    var out = [];
    var cs = [makeCounter(0), makeCounter(10), makeCounter(100)];
    for (var r = 0; r < 4; r++) for (var i = 0; i < cs.length; i++) out.push(cs[i]());
    return out.join(',') + '|' + consts('q');
}

eq(typedRows(), "0 1 -1 127 -128 -1 0 127 -1 0 -1 0 -1 0 -1 0 1 -1 1\n1 -1 2 -1 -2 0 -1 0 0 -1 0 0 0 0 0 0\n0 1 255 127 128 255 0 127 255 0 255 0 255 0 255 0 1 255 1\n1 255 2 255 254 0 255 0 0 255 0 0 0 0 0 0\n0 1 0 127 128 255 255 0 255 255 255 255 255 0 255 255 255 0 255\n2 0 2 255 254 0 255 0 255 0 255 255 0 0 255 0\n0 1 -1 127 128 255 256 -129 32767 -32768 -1 0 -1 0 -1 0 1 -1 1\n1 -1 2 255 254 0 -1 0 0 -1 0 0 0 0 0 0\n0 1 65535 127 128 255 256 65407 32767 32768 65535 0 65535 0 65535 0 1 65535 1\n1 65535 2 255 254 0 65535 0 0 65535 0 0 0 0 0 0\n0 1 -1 127 128 255 256 -129 32767 32768 65535 65536 2147483647 -2147483648 -1 0 1 -1 16777217\n1 -1 2 255 254 0 2147483647 -2147483648 -2147483648 2147483647 0 1661992960 -1661992960 0 0 0\n0 1 4294967295 127 128 255 256 4294967167 32767 32768 65535 65536 2147483647 2147483648 4294967295 0 1 4294967295 16777217\n1 4294967295 2 255 254 0 2147483647 2147483648 2147483648 2147483647 0 1661992960 2632974336 0 0 0\n0 1 -1 127 128 255 256 -129 32767 32768 65535 65536 2147483648 -2147483648 4294967296 4294967296 8589934592 -8589934592 16777216\n1.5 -1.5 2.5 255.5 254.5 -0.5 2147483648 -2147483648 2147483648 -2147483648 4294967296 100000002004087730000 -100000002004087730000 NaN Infinity -Infinity\n0 1 -1 127 128 255 256 -129 32767 32768 65535 65536 2147483647 -2147483648 4294967295 4294967296 8589934593 -8589934593 16777217\n1.5 -1.5 2.5 255.5 254.5 -0.5 2147483647.5 -2147483648.5 2147483648.25 -2147483649.75 4294967296.5 100000000000000000000 -100000000000000000000 NaN Infinity -Infinity\n1 1 -2 -1 4294967295 0 2 2 -3 255 255 -256 254 254 -255 0 0 -1 2147483647 2147483647 -2147483648 -2147483648 2147483648 2147483647 -2147483648 2147483648 2147483647 2147483647 2147483647 -2147483648 0 0 -1 1661992960 1661992960 -1661992961 -1661992960 2632974336 1661992959 0 0 -1 0 0 -1 0 0 -1", "typed array stores and ToInt32");
eq(scopes(), "1,11,101,2,12,102,3,13,103,4,14,104|nulltruefalse", "variable caches and constants");

print("threaded_leaf_paths: " + pass + " passed, " + fail + " failed");
if (fail > 0) { print("SOME TESTS FAILED"); throw new Error("FAIL"); }
