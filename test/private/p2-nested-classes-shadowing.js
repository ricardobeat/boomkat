// P2: a nested class may declare a private name with the same source text
// (#x) as an enclosing class. Each is a distinct private name; the inner
// class's #x shadows the outer one inside the inner class's own methods,
// while the outer method still sees the outer #x.
class A {
    #x = 1;
    m() {
        class B {
            #x = 2;
            m2() { return this.#x; }
        }
        return [this.#x, new B().m2()];
    }
}

var result = new A().m();
if (result[0] !== 1) throw new Error("expected outer #x === 1, got " + result[0]);
if (result[1] !== 2) throw new Error("expected inner #x === 2, got " + result[1]);

print("PASS");
