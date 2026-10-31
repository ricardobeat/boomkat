// Compare direct indexed reads/writes with the constructor's scalar path.
// This exercises integer and floating element kinds, rounding boundaries and
// integers at the edge of the fastint representation.
var typedKinds = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
                  Int32Array, Uint32Array, Float32Array, Float64Array];
if (typeof Float16Array === 'function') typedKinds.push(Float16Array);
var typedNumbers = [0, -0, 1, -1, 127, 128, 254, 255, 256, -128, -129,
                    32767, 32768, 65535, 65536, 2147483647, 2147483648,
                    4294967295, -2147483649, 16777217, 1099511627775,
                    140737488355327, -140737488355327, -140737488355328,
                    1.5, 2.5, NaN, Infinity, -Infinity];
function typedStoreRead(view, index, value) { view[index] = value; return view[index]; }
for (var k = 0; k < typedKinds.length; k++) {
    var C = typedKinds[k], view = new C(typedNumbers.length);
    for (var round = 0; round < 4; round++) {
        for (var i = 0; i < typedNumbers.length; i++) {
            var value = typedNumbers[i];
            var expected = new C([value])[0];
            var actual = typedStoreRead(view, i, value);
            if (!Object.is(actual, expected)) throw Error(C.name + ' index ' + i + ': ' + actual + ' != ' + expected);
        }
    }
}
var effects = 0, byteView = new Uint8Array(1);
var objectValue = { valueOf: function () { effects++; return 257; } };
if (typedStoreRead(byteView, 0, objectValue) !== 1 || effects !== 1) throw Error('coercion');
var detached = new ArrayBuffer(4), detachedView = new Uint8Array(detached);
detached.transfer();
if (typedStoreRead(detachedView, 0, 8) !== undefined) throw Error('detached view');
var resizable = new ArrayBuffer(8, {maxByteLength: 16}), tracking = new Uint8Array(resizable);
tracking[7] = 42; resizable.resize(4);
if (typedStoreRead(tracking, 7, 9) !== undefined || tracking.length !== 4) throw Error('resized view');
var big = new BigInt64Array(1), threw = false;
try { typedStoreRead(big, 0, 1); } catch (e) { threw = e instanceof TypeError; }
if (!threw) throw Error('BigInt conversion');
console.log('threaded typed array numeric paths: PASS');
