// TypedArray [[Delete]] (§10.4.5.6) refuses a valid integer index and accepts
// any other numeric key. Reflect.deleteProperty and a trapless Proxy reach it
// without the delete operator, so they need the same answer.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var ta = new Uint8Array([7, 8, 9, 10]);
check("Reflect valid index", Reflect.deleteProperty(ta, "1"), false);
check("Reflect valid index keeps value", ta[1], 8);
check("Reflect out of range", Reflect.deleteProperty(ta, "9"), true);
check("Reflect -0", Reflect.deleteProperty(ta, "-0"), true);
check("Reflect fractional", Reflect.deleteProperty(ta, "1.5"), true);
ta.extra = 1;
check("Reflect named property", Reflect.deleteProperty(ta, "extra"), true);
check("named property gone", "extra" in ta, false);

var px = new Proxy(ta, {});
check("trapless proxy valid index", Reflect.deleteProperty(px, "2"), false);
check("trapless proxy keeps value", ta[2], 9);
check("trapless proxy out of range", Reflect.deleteProperty(px, "4"), true);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
