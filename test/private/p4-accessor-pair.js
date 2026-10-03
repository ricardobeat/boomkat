// P4: a get/set pair sharing the same private name behaves like a normal
// accessor property.
class A {
    #v = 0;
    get #x() { return this.#v; }
    set #x(nv) { this.#v = nv; }

    read() { return this.#x; }
    write(nv) { this.#x = nv; }
}

var a = new A();
if (a.read() !== 0) throw new Error("expected 0, got " + a.read());
a.write(9);
if (a.read() !== 9) throw new Error("expected 9, got " + a.read());

print("PASS");
