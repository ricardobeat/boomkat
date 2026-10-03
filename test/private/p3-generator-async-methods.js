// P3: private generator and async methods work like their public
// counterparts.
class A {
    *#gen() { yield 1; yield 2; }
    collect() { return Array.from(this.#gen()); }

    async #am() { return 42; }
    callAsync() { return this.#am(); }
}

var a = new A();
var items = a.collect();
if (items.length !== 2 || items[0] !== 1 || items[1] !== 2) {
    throw new Error("expected [1, 2], got " + JSON.stringify(items));
}

a.callAsync().then(function (v) {
    if (v !== 42) throw new Error("expected 42, got " + v);
    print("PASS");
}, function (e) {
    throw new Error("async private method rejected: " + e);
});
