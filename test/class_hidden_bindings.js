// Every class declares hidden bindings named after its ordinal
// (__super__N, __static_super__N, __home_object__N). Their scope entries
// outlive the parse of the class, so a later lookup of a same-length name
// compares against them: the entries must still hold their names.
var passed = 0;

function check(name, actual, expected) {
    if (actual !== expected) {
        throw new Error(name + ": expected " + expected + ", got " + actual);
    }
    passed++;
}

var abcdefghi = 1;          // length of __super__0
var abcdefghijklmnopq = 2;  // length of __static_super__0
var abcdefghijklmno = 3;    // length of __home_object__0
class A { m() { return super.constructor === Object; } static s() { return typeof super.call; } }
class B extends A { constructor() { super(); } m() { return super.m(); } }
check("a name as long as __super__0", abcdefghi, 1);
check("a name as long as __static_super__0", abcdefghijklmnopq, 2);
check("a name as long as __home_object__0", abcdefghijklmno, 3);
check("super in an instance method", new B().m(), true);
check("super in a static method", B.s(), "function");

function inner() {
    var abcdefghij = 4;     // length of __super__10 onwards
    class C {}
    class D extends C {}
    return abcdefghij;
}
check("the same inside a function", inner(), 4);

print("class_hidden_bindings: " + passed + " passed");
