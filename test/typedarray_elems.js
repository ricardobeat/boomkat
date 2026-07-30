// Plan 049 stage 2 oracle: TypedArray construction + element access.
var failures = 0;
function check(cond, msg) {
    if (!cond) {
        failures++;
        print("FAIL: " + msg);
    }
}

// --- Each of the 9 classes: new X(4) ---
var classes = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array,
               Int32Array, Uint32Array, Float32Array, Float64Array];
var sizes = [1, 1, 1, 2, 2, 4, 4, 4, 8];
for (var ci = 0; ci < classes.length; ci++) {
    var X = classes[ci];
    var t = new X(4);
    check(t.length === 4, X.name + " length");
    check(t.byteLength === 4 * sizes[ci], X.name + " byteLength");
    check(t.byteOffset === 0, X.name + " byteOffset");
    check(t.buffer instanceof ArrayBuffer, X.name + " buffer instanceof ArrayBuffer");
}

// --- new X(buf, off, len) shared view ---
var buf = new ArrayBuffer(16);
var view1 = new Int32Array(buf, 4, 2);
check(view1.length === 2, "shared view length");
check(view1.byteOffset === 4, "shared view byteOffset");
check(view1.buffer === buf, "shared view buffer identity");
view1[0] = 42;
var view2 = new Uint8Array(buf);
check(view2[4] === 42, "shared view reflects through buffer (LE byte 0)");

// --- Numeric write/read round-trip with correct truncation ---
var i8 = new Int8Array(2);
i8[0] = 128; check(i8[0] === -128, "Int8 wraps 128 -> -128");
i8[0] = 300; check(i8[0] === 44, "Int8 wraps 300 -> 44");

var u8 = new Uint8Array(2);
u8[0] = -1; check(u8[0] === 255, "Uint8 wraps -1 -> 255");
u8[0] = 256; check(u8[0] === 0, "Uint8 wraps 256 -> 0");

var uc = new Uint8ClampedArray(6);
uc[0] = -5; check(uc[0] === 0, "Uint8Clamped -5 -> 0");
uc[1] = 300; check(uc[1] === 255, "Uint8Clamped 300 -> 255");
uc[2] = 1.5; check(uc[2] === 2, "Uint8Clamped 1.5 -> 2 (round half to even)");
uc[3] = 2.5; check(uc[3] === 2, "Uint8Clamped 2.5 -> 2 (round half to even)");
uc[4] = 3.5; check(uc[4] === 4, "Uint8Clamped 3.5 -> 4 (round half to even)");
uc[5] = NaN; check(uc[5] === 0, "Uint8Clamped NaN -> 0");

var i16 = new Int16Array(1);
i16[0] = 32768; check(i16[0] === -32768, "Int16 wraps 32768 -> -32768");
var u16 = new Uint16Array(1);
u16[0] = -1; check(u16[0] === 65535, "Uint16 wraps -1 -> 65535");
var i32 = new Int32Array(1);
i32[0] = 2147483648; check(i32[0] === -2147483648, "Int32 wraps 2^31 -> -2^31");
var u32 = new Uint32Array(1);
u32[0] = -1; check(u32[0] === 4294967295, "Uint32 wraps -1 -> 4294967295");

var f32 = new Float32Array(1);
f32[0] = 1.1;
check(f32[0] !== 1.1, "Float32 1.1 loses precision");
check(Math.abs(f32[0] - 1.1) < 0.001, "Float32 1.1 approx preserved");

var f64 = new Float64Array(1);
f64[0] = 1.1;
check(f64[0] === 1.1, "Float64 1.1 exact");

// --- OOB read/write ---
var oob = new Int8Array(2);
check(oob[5] === undefined, "OOB read returns undefined");
oob[5] = 9; // silently ignored, no throw
check(true, "OOB write did not throw");

// --- Detach ---
var dbuf = new ArrayBuffer(4);
var dta = new Int32Array(dbuf);
dta[0] = 7;
check(dta[0] === 7, "pre-detach read works");
__detachArrayBuffer(dbuf);
check(dta.length === 0, "length is 0 after detach");
check(dta.byteLength === 0, "byteLength is 0 after detach");
check(dta[0] === undefined, "read after detach yields undefined");

// --- From another TypedArray: same-class memcpy path ---
var src8 = new Int8Array([1, 2, 3]);
var dst8 = new Int8Array(src8);
check(dst8.length === 3 && dst8[0] === 1 && dst8[1] === 2 && dst8[2] === 3, "same-class TA copy");
check(dst8.buffer !== src8.buffer, "same-class TA copy uses a fresh buffer");

// --- From another TypedArray: cross-class conversion path ---
var srcF = new Float64Array([1.9, -2.9, 300]);
var dstI = new Int8Array(srcF);
check(dstI[0] === 1, "cross-class TA copy truncates 1.9 -> 1");
check(dstI[1] === -2, "cross-class TA copy truncates -2.9 -> -2");
check(dstI[2] === 44, "cross-class TA copy wraps 300 -> 44");

// --- From an iterable (plain array) ---
var fromArr = new Uint16Array([10, 20, 30]);
check(fromArr.length === 3 && fromArr[0] === 10 && fromArr[1] === 20 && fromArr[2] === 30, "TA from iterable array");

// --- From an array-like (no Symbol.iterator) ---
var arrayLike = { 0: 5, 1: 6, length: 2 };
var fromLike = new Int32Array(arrayLike);
check(fromLike.length === 2 && fromLike[0] === 5 && fromLike[1] === 6, "TA from array-like object");

// --- Symbol.toStringTag ---
check(Object.prototype.toString.call(new Int8Array()) === "[object Int8Array]", "toStringTag Int8Array");
check(Object.prototype.toString.call(new Float64Array()) === "[object Float64Array]", "toStringTag Float64Array");

// --- Enumeration / has / delete / descriptor ---
var enumTA = new Int8Array([10, 20, 30]);
var keys = [];
for (var k in enumTA) keys.push(k);
check(keys.join(",") === "0,1,2", "for-in yields indices");
check((0 in enumTA) === true, "in operator true for in-range index");
check((5 in enumTA) === false, "in operator false for OOB index");
// §10.4.5.4 [[Delete]] on an integer-indexed exotic returns false for a valid
// index and true for an invalid one. This engine runs everything as strict
// code, and the delete operator throws a TypeError when [[Delete]] returns
// false (§13.5.1.2 step 5) — so the in-range delete is observed as a throw
// rather than as `false`.
var deleteThrew = false;
try {
    delete enumTA[0];
} catch (e) {
    deleteThrew = e instanceof TypeError;
}
check(deleteThrew, "delete in-range index throws TypeError in strict code");
check(enumTA[0] === 10, "delete did not remove in-range element");
check(delete enumTA[10] === true, "delete OOB index returns true");
var desc = Object.getOwnPropertyDescriptor(enumTA, 1);
check(desc !== undefined && desc.value === 20 && desc.writable === true
    && desc.enumerable === true && desc.configurable === true, "getOwnPropertyDescriptor shape");

// --- CanonicalNumericIndexString ---
var cniTA = new Int8Array([1, 2, 3]);
check(cniTA["1.5"] === undefined, "CNI read '1.5' -> undefined");
cniTA["1.5"] = 99;
check(cniTA["1.5"] === undefined, "CNI write '1.5' ignored");
check(cniTA["NaN"] === undefined, "CNI read 'NaN' -> undefined");
check(cniTA["-0"] === undefined, "CNI read '-0' -> undefined");

if (failures === 0) {
    print("PASS");
} else {
    print("FAILURES: " + failures);
}
