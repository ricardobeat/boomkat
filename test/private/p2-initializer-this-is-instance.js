// P2: `this` inside a field initializer is the instance being constructed.
class A {
    #tag = "instance";
    #self = this;
    isSelf() { return this.#self === this; }
    getTag() { return this.#self.#tag; }
}

var a = new A();
if (a.isSelf() !== true) throw new Error("this inside initializer should be the new instance");
if (a.getTag() !== "instance") throw new Error("expected 'instance', got " + a.getTag());

print("PASS");
