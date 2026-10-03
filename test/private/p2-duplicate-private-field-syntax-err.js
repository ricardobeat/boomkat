// P2: declaring the same private field name twice in one class is a
// SyntaxError (unlike a getter/setter pair, which is legal).
class A {
    #x = 1;
    #x = 2;
}
