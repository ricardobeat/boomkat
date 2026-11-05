// A typed array on the prototype chain answers integer-indexed keys itself
// (ECMA-262 10.4.5.2 [[HasProperty]], 10.4.5.4 [[Get]]): a valid index reads
// the element, and any other canonical numeric string ("-0", "1.5", "NaN",
// out of range) ends the lookup instead of reaching Object.prototype.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

["1.5", "-0", "NaN", "7", "-1", "Infinity"].forEach(function (k) {
    Object.defineProperty(Object.prototype, k, { value: "leak", configurable: true });
});

var ta = new Int32Array([4, 5]);
var o = Object.create(ta);
var oo = Object.create(o);

check("get index", o[1], 5);
check("get index string", o["0"], 4);
check("get depth 2", oo[1], 5);
["1.5", "-0", "NaN", "7", "-1", "Infinity"].forEach(function (k) {
    check("get " + k, o[k], undefined);
    check("get depth 2 " + k, oo[k], undefined);
    check("in " + k, k in o, false);
    check("Reflect.get " + k, Reflect.get(oo, k), undefined);
    check("Reflect.has " + k, Reflect.has(oo, k), false);
});
check("in index", 1 in oo, true);
check("Reflect.get receiver", Reflect.get(oo, "1", {}), 5);
check("Reflect.has index", Reflect.has(oo, 0), true);

var s = 0;
for (var i = 0; i < 50; i++) s += oo[i & 1];
check("repeated reads", s, 225);

var w;
with (o) { w = [typeof NaN, Infinity]; }
check("with NaN binding", w[0], "number");

// [[Set]] through the chain: a valid index defines on the receiver, an
// invalid one is a no-op.
oo[1] = 9;
check("set defines on receiver", Object.getOwnPropertyDescriptor(oo, "1").value, 9);
check("set leaves element", ta[1], 5);
oo[7] = 1;
check("set invalid index is a no-op", oo.hasOwnProperty("7"), false);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
