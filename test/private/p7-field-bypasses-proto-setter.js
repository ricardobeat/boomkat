// P7: instance field initialization uses CreateDataPropertyOrThrow, which
// does NOT invoke an inherited accessor's setter. A base class setter for
// the same key must never fire when a derived class declares that key as
// a public field.
var setterCalls = 0;
class Base {
    set x(v) { setterCalls++; }
}
class Derived extends Base {
    x = 5;
}

var d = new Derived();
if (setterCalls !== 0) throw new Error("expected inherited setter not to fire, but it fired " + setterCalls + " times");

var desc = Object.getOwnPropertyDescriptor(d, "x");
if (!desc || desc.value !== 5 || !("value" in desc)) {
    throw new Error("expected own data property x=5, got " + JSON.stringify(desc));
}

print("PASS");
