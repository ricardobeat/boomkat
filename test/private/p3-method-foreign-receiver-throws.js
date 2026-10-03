// P3: calling a private method with a receiver that isn't a branded
// instance of the declaring class throws TypeError.
class A {
    #m() { return 1; }
    call() { return this.#m(); }
}

var a = new A();
if (a.call() !== 1) throw new Error("sanity check failed");

var threw = false;
try {
    a.call.call({});
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError calling private method with foreign receiver");

print("PASS");
