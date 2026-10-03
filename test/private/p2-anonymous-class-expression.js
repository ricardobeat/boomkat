// P2: anonymous class expressions can declare and use private fields.
var Wrapper = class {
    #v;
    constructor(v) { this.#v = v; }
    get() { return this.#v; }
};

var w = new Wrapper(7);
if (w.get() !== 7) throw new Error("expected 7, got " + w.get());

var w2 = new (class { #tag = "anon"; getTag() { return this.#tag; } })();
if (w2.getTag() !== "anon") throw new Error("expected 'anon', got " + w2.getTag());

print("PASS");
