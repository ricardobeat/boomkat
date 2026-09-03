// Object.prototype.propertyIsEnumerable, ES5 §15.2.4.7: step 2 is
// `O = ToObject(this value)`, so a primitive `this` (a string, number,
// boolean) must be boxed into its exotic wrapper before the property check
// -- e.g. an in-range string index is an enumerable own property of the
// wrapper. The implementation instead returned false unconditionally for
// any non-object `this`, dead-coding an already-correct STRING-exotic
// branch further down (which checks obj.flags.exotic_stringobj, but `obj`
// was never actually set to a string wrapper).

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var propertyIsEnumerable = Object.prototype.propertyIsEnumerable;

check("in-range string index is enumerable", propertyIsEnumerable.call("s", 0), true);
check("out-of-range string index is not enumerable", propertyIsEnumerable.call("s", 1), false);
check("string .length is not enumerable", propertyIsEnumerable.call("s", "length"), false);
check("boxed number has no own enumerable props by default", propertyIsEnumerable.call(5, "toString"), false);
check("boxed boolean toString is not enumerable (inherited)", propertyIsEnumerable.call(true, "toString"), false);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
