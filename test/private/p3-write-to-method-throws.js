// P3: private methods are not writable — assigning to this.#m throws
// TypeError (there is no [[Set]] target; methods live on the prototype
// with no matching field slot).
class A {
    #m() {}
    write() { this.#m = 5; }
}

var a = new A();
var threw = false;
try {
    a.write();
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError writing to a private method");

print("PASS");
