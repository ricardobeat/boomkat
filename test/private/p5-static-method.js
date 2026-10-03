// P5: static private methods are callable via ClassName.#m() (or this.#m()
// with `this` bound to the class) from other static members.
class A {
    static #helper(v) { return v * 2; }
    static compute(v) { return A.#helper(v) + 1; }
}

if (A.compute(3) !== 7) throw new Error("expected 7, got " + A.compute(3));

print("PASS");
