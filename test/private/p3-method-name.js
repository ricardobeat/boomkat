// P3: a private method's .name is "#m" (the hash is part of the name).
class A {
    #m() {}
    getName() { return this.#m.name; }
}

var a = new A();
if (a.getName() !== "#m") throw new Error("expected '#m', got " + JSON.stringify(a.getName()));

print("PASS");
