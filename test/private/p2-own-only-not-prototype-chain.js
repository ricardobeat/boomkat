// P2: private field access is own-property-only; it must not walk the
// prototype chain. An object that merely inherits from a branded instance
// is not itself branded.
class A {
    #x = 1;
    getX() { return this.#x; }
}

var a = new A();
var b = Object.create(a);

var threw = false;
try {
    a.getX.call(b);
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError: private field must not be found via prototype chain");

print("PASS");
