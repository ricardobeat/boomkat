// P5: a static private field is a single shared value on the class itself,
// accessible from static methods via `this.#x`.
class Counter {
    static #count = 0;
    static inc() { return ++Counter.#count; }
    static get() { return this.#count; }
}

if (Counter.get() !== 0) throw new Error("expected 0, got " + Counter.get());
Counter.inc();
Counter.inc();
if (Counter.get() !== 2) throw new Error("expected 2, got " + Counter.get());

print("PASS");
