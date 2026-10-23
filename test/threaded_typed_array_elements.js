// Threaded typed array element reads and writes.
//
// GETPROP/PUTPROP with a fastint index on a typed array used to leave the
// threaded burst for the switch on every access. The threaded path takes a
// fixed-length, attached array, an in-bounds index and, for a store, a
// number; everything else (out of bounds, resizable buffers, values that
// convert) must keep the switch's behavior. Expected values are from node.

var kinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
             Int32Array, Uint32Array, Float32Array, Float64Array];
var inputs = [0, -0, 1, -1, 127, 128, 255, 256, -129, 1.5, 2.5, -1.5, 65535.7,
              2147483647, 2147483648, 4294967295, -2147483649, 1e20, NaN, Infinity, -Infinity];
function fmt(v) { return Object.is(v, -0) ? '-0' : String(v); }
function fill(ta) {
    // Fastint and double indices, in and out of bounds.
    for (var i = 0; i < inputs.length; i++) ta[i] = inputs[i];
    ta[-1] = 7; ta[ta.length] = 7; ta[1.5] = 7;
}
function read(ta) {
    var out = [];
    for (var i = -1; i <= ta.length; i++) out.push(fmt(ta[i]));
    return out.join(' ');
}
function table() {
    var rows = [];
    for (var round = 0; round < 3; round++) {
        for (var k = 0; k < kinds.length; k++) {
            var ta = new kinds[k](inputs.length);
            fill(ta);
            rows.push(read(ta) + '|' + fmt(ta[1.5]) + '|' + Object.keys(ta).length);
        }
        // A view at an offset into a shared buffer.
        var buf = new ArrayBuffer(16), whole = new Uint8Array(buf), part = new Int16Array(buf, 4, 3);
        for (var i = 0; i < 3; i++) part[i] = -2 - i;
        rows.push(read(whole) + '|' + read(part));
        // A resizable buffer's tracking view shrinks with it.
        if (typeof ArrayBuffer.prototype.resize == 'function') {
            var rb = new ArrayBuffer(8, { maxByteLength: 16 }), tv = new Uint8Array(rb);
            for (var i = 0; i < 8; i++) tv[i] = i + 1;
            rb.resize(4);
            tv[5] = 9;
            rows.push(read(tv) + '|' + tv.length);
        }
        // Non-number values still convert.
        var conv = new Int32Array(4);
        conv[0] = '12'; conv[1] = true; conv[2] = { valueOf: function () { return 5; } }; conv[3] = undefined;
        rows.push(read(conv));
    }
    return rows.join('\n');
}
var expected = "undefined 0 0 1 -1 127 -128 -1 0 127 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 255 127 128 255 0 127 1 2 255 255 255 0 255 255 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 0 127 128 255 255 0 2 2 0 255 255 255 255 0 255 0 255 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 65535 127 128 255 256 65407 1 2 65535 65535 65535 0 65535 65535 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 65535 2147483647 -2147483648 -1 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 0 1 4294967295 127 128 255 256 4294967167 1 2 4294967295 65535 2147483647 2147483648 4294967295 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.69921875 2147483648 2147483648 4294967296 -2147483648 100000002004087730000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.7 2147483647 2147483648 4294967295 -2147483649 100000000000000000000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 0 0 0 254 255 253 255 252 255 0 0 0 0 0 0 undefined|undefined -2 -3 -4 undefined\nundefined 1 2 3 4 undefined|4\nundefined 12 1 5 0 undefined\nundefined 0 0 1 -1 127 -128 -1 0 127 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 255 127 128 255 0 127 1 2 255 255 255 0 255 255 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 0 127 128 255 255 0 2 2 0 255 255 255 255 0 255 0 255 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 65535 127 128 255 256 65407 1 2 65535 65535 65535 0 65535 65535 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 65535 2147483647 -2147483648 -1 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 0 1 4294967295 127 128 255 256 4294967167 1 2 4294967295 65535 2147483647 2147483648 4294967295 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.69921875 2147483648 2147483648 4294967296 -2147483648 100000002004087730000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.7 2147483647 2147483648 4294967295 -2147483649 100000000000000000000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 0 0 0 254 255 253 255 252 255 0 0 0 0 0 0 undefined|undefined -2 -3 -4 undefined\nundefined 1 2 3 4 undefined|4\nundefined 12 1 5 0 undefined\nundefined 0 0 1 -1 127 -128 -1 0 127 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 255 127 128 255 0 127 1 2 255 255 255 0 255 255 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 0 127 128 255 255 0 2 2 0 255 255 255 255 0 255 0 255 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 -1 -1 0 -1 -1 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 65535 127 128 255 256 65407 1 2 65535 65535 65535 0 65535 65535 0 0 0 0 undefined|undefined|21\nundefined 0 0 1 -1 127 128 255 256 -129 1 2 -1 65535 2147483647 -2147483648 -1 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 0 1 4294967295 127 128 255 256 4294967167 1 2 4294967295 65535 2147483647 2147483648 4294967295 2147483647 1661992960 0 0 0 undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.69921875 2147483648 2147483648 4294967296 -2147483648 100000002004087730000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 -0 1 -1 127 128 255 256 -129 1.5 2.5 -1.5 65535.7 2147483647 2147483648 4294967295 -2147483649 100000000000000000000 NaN Infinity -Infinity undefined|undefined|21\nundefined 0 0 0 0 254 255 253 255 252 255 0 0 0 0 0 0 undefined|undefined -2 -3 -4 undefined\nundefined 1 2 3 4 undefined|4\nundefined 12 1 5 0 undefined";
var got = table();
if (got !== expected) {
    var g = got.split('\n'), e = expected.split('\n');
    for (var i = 0; i < e.length; i++) if (g[i] !== e[i]) print('FAIL row ' + i + ':\n  got  ' + g[i] + '\n  want ' + e[i]);
    throw new Error('FAIL');
}
print('threaded_typed_array_elements: passed');
