// P2: accessing a private field on an object that isn't a (branded)
// instance of the declaring class throws TypeError.
class A {
    #x = 1;
    getX() { return this.#x; }
}

var a = new A();
if (a.getX() !== 1) throw new Error("sanity check failed");

var threw = false;
try {
    a.getX.call({});
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError calling getX with foreign receiver");

print("PASS");
