// P2: referencing a private name that the enclosing class never declared
// is an early (compile-time) SyntaxError — there is no get-or-create.
class A {
    #x = 1;
    getY() { return this.#y; }
}
