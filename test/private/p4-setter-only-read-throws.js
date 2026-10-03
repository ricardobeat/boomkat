// P4: a setter-only private accessor throws TypeError on read.
class A {
    set #x(v) {}
    read() { return this.#x; }
}

var a = new A();
var threw = false;
try {
    a.read();
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError reading a setter-only private accessor");

print("PASS");
