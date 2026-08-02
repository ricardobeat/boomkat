// Private-slot class ids come from a per-runtime counter on the heap, shared
// by every compiler context in that runtime. A per-context counter would
// restart inside a nested arrow context, and two sibling classes whose slot
// bindings land in the same runtime env would collide on "#priv:<id>:x":
// the second field init would overwrite the first's symbol, and both getters
// would read the same one.

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Sibling classes where one is compiled inside a nested arrow context.
function siblingAcrossArrow() {
    class A { #x = 1; get() { return this.#x; } }
    const mk = () => { class B { #x = 2; get() { return this.#x; } } return B; };
    const B = mk();
    return [new A().get(), new B().get()];
}

var r = siblingAcrossArrow();
assert(r[0] === 1, 'class A keeps its own private slot');
assert(r[1] === 2, 'class B in an arrow gets its own private slot');

// Sibling classes at the same scope.
class S1 { #v = 10; get() { return this.#v; } }
class S2 { #v = 20; get() { return this.#v; } }
assert(new S1().get() === 10 && new S2().get() === 20, 'same-scope sibling classes keep distinct slots');

// Nested classes.
class Outer {
    #o = 1;
    get() { return this.#o; }
    static makeInner() {
        return class Inner { #o = 2; get() { return this.#o; } };
    }
}
var Inner = Outer.makeInner();
assert(new Outer().get() === 1 && new Inner().get() === 2, 'nested classes keep distinct slots');

// Class definitions repeated across separate evals still bind their own slot.
function fresh() {
    class F { #z = 42; get() { return this.#z; } }
    return new F().get();
}
assert(fresh() === 42 && fresh() === 42, 'redefined classes still bind their own slot');

print('pass: ' + pass + ' fail: ' + fail);
