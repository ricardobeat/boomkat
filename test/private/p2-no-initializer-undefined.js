// P2: a private field declared without an initializer starts as undefined.
class A {
    #x;
    getX() { return this.#x; }
    setX(v) { this.#x = v; }
}

var a = new A();
if (a.getX() !== undefined) throw new Error("expected undefined, got " + a.getX());
a.setX(42);
if (a.getX() !== 42) throw new Error("expected 42, got " + a.getX());

print("PASS");
