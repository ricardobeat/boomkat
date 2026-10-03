// P5: static private members are stamped only on the class object, not on
// instances. Accessing them with `this` bound to an instance throws
// TypeError, same as accessing them on an unrelated object.
class A {
    static #x = 1;
    getX() { return this.#x; }
}

var threw = false;
try {
    new A().getX();
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError accessing static private field via instance receiver");

print("PASS");
