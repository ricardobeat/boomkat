// P2: new.target inside a field initializer is always undefined, even
// though the initializer runs during a `new` construction.
class A {
    #nt = new.target;
    getNt() { return this.#nt; }
}

var a = new A();
if (a.getNt() !== undefined) throw new Error("expected undefined, got " + a.getNt());

print("PASS");
