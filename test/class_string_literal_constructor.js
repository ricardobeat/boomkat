// A class method named via a plain string literal ("constructor") is the
// real class constructor, exactly like the bareword form (constructor()).
// Only a genuine ComputedPropertyName (["constructor"], [`constructor`])
// is NOT special -- PropName of a computed key is never statically known
// to be "constructor" (ES2022 §15.7.6 ConstructorMethod), so it defines an
// ordinary method and the class gets its normal, auto-generated
// constructor instead.
//
// The constructor-name check used to live only inside the parser's
// IDENTIFIER/keyword name-parsing branch, so a string-literal name never
// reached it and was always treated as an ordinary method.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- string literal name: real constructor, `this` replaced by the return value ---
{
    class A {
        "constructor"() { return {}; }
    }
    var a = new A();
    check("string-literal constructor: not an instance (this was replaced)", a instanceof A, false);
    check("string-literal constructor: proto is Object.prototype", Object.getPrototypeOf(a), Object.prototype);
}

// --- identifier name: same behavior (already worked, kept as a baseline) ---
{
    class B {
        constructor() { return {}; }
    }
    var b = new B();
    check("identifier constructor: not an instance", b instanceof B, false);
}

// --- computed key, even a collapsed string literal: NOT the constructor ---
{
    class C {
        ["constructor"]() { return {}; }
    }
    var c = new C();
    check("computed-key constructor: still an instance (ordinary method, default ctor ran)", c instanceof C, true);
    check("computed-key constructor: default ctor did not invoke the method", typeof c.constructor, "function");
}

// --- extends form from the SM regression test ---
{
    class D extends class {} {
        "constructor"() { return {}; }
    }
    var d = new D();
    check("string-literal constructor in a derived class: not an instance", d instanceof D, false);
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
