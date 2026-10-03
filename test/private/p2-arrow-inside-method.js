// P2: an arrow function nested inside a method closes over the enclosing
// method's `this`, so it can access private fields through this.#x.
class A {
    #x = 5;
    m() {
        var f = () => this.#x;
        return f();
    }
    mapper(list) {
        var self = this;
        return list.map(function (v) { return v + self.#x; });
    }
}

var a = new A();
if (a.m() !== 5) throw new Error("expected 5, got " + a.m());

print("PASS");
