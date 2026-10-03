// P3: private methods are callable via this.#m() from inside the class.
class A {
    #greet() { return "hi"; }
    call() { return this.#greet(); }
}

var a = new A();
if (a.call() !== "hi") throw new Error("expected 'hi', got " + a.call());

print("PASS");
