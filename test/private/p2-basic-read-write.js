// P2: basic private field read/write.
class Counter {
    #count = 0;
    inc() { this.#count = this.#count + 1; return this.#count; }
    get() { return this.#count; }
}

var c = new Counter();
if (c.get() !== 0) throw new Error("initial value should be 0, got " + c.get());
c.inc();
c.inc();
if (c.get() !== 2) throw new Error("after two incs should be 2, got " + c.get());

print("PASS");
