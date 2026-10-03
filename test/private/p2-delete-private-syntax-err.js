// P2: `delete this.#x` is a SyntaxError — private references can never be
// the operand of a delete expression.
class A {
    #x = 1;
    m() { delete this.#x; }
}
