// P2: a method may reference a private field declared later in the class
// body — private-name declaration happens in a pre-scan, before any bodies
// (including field initializers) are compiled/executed.
class A {
    getY() { return this.#y; }
    #y = 99;
}

var a = new A();
if (a.getY() !== 99) throw new Error("expected 99, got " + a.getY());

print("PASS");
