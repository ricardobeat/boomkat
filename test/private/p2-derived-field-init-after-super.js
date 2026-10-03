// P2: in a derived class, private field initializers run right after
// super() returns (not at constructor entry), and reading this.#x before
// super() has run throws a ReferenceError (this is in the TDZ).
var log = [];
class Base {
    constructor() { log.push("base-ctor"); }
}
class Derived extends Base {
    #x = (log.push("field-init"), 5);
    constructor() {
        var threw = false;
        try {
            this.#x;
        } catch (e) {
            threw = true;
            if (!(e instanceof ReferenceError)) throw new Error("expected ReferenceError, got " + e);
        }
        if (!threw) throw new Error("expected ReferenceError reading this.#x before super()");
        log.push("before-super-checked");
        super();
        log.push("after-super");
    }
    getX() { return this.#x; }
}

var d = new Derived();
if (d.getX() !== 5) throw new Error("expected 5, got " + d.getX());
var expected = "before-super-checked,base-ctor,field-init,after-super";
var actual = log.join(",");
if (actual !== expected) throw new Error("expected order " + expected + ", got " + actual);

print("PASS");
