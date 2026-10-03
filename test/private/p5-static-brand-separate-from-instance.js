// P5: the static-side brand is distinct from the instance-side brand.
// A prototype method that reads a static private method through `this`
// only succeeds when `this` is the class itself, not any instance.
class A {
    static #m() { return 1; }
    callIt() { return this.#m(); }
}

var threw = false;
try {
    new A().callIt();
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError: instance is not branded with the static-side private method");

if (A.prototype.callIt.call(A) !== 1) throw new Error("expected 1 when receiver is the class itself");

print("PASS");
