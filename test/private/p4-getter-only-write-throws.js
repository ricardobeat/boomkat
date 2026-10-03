// P4: a getter-only private accessor throws TypeError on write.
class A {
    get #x() { return 1; }
    write() { this.#x = 5; }
}

var a = new A();
var threw = false;
try {
    a.write();
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError writing to a getter-only private accessor");

print("PASS");
