// P2: each *evaluation* of a class expression creates fresh private names.
// Two classes produced by separate calls to the same factory function are
// not interchangeable, even though they share identical source text.
function make() {
    return class {
        #x = 1;
        static get(o) { return o.#x; }
    };
}

var A = make();
var B = make();

if (A.get(new A()) !== 1) throw new Error("sanity check on A failed");
if (B.get(new B()) !== 1) throw new Error("sanity check on B failed");

var threw = false;
try {
    A.get(new B());
} catch (e) {
    threw = true;
    if (!(e instanceof TypeError)) throw new Error("expected TypeError, got " + e);
}
if (!threw) throw new Error("expected TypeError: A's #x must not be reachable on a B instance");

print("PASS");
