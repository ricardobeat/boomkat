// super.x / super[x] in an instance method must resolve
// Object.getPrototypeOf(HomeObject) freshly on every access (ES2022
// §13.3.7.1 GetSuperBase), where HomeObject is the class's own .prototype.
// The engine used to bind __super__ = the parent constructor at class-
// definition time and read __super__.prototype directly -- a snapshot that
// never observed a later Object.setPrototypeOf on the class's own
// .prototype, and was never null even when it should be.
//
// Fixing this touches the SAME super.x resolution machinery object literals
// use (concise methods bind their own unnumbered "__super__" to the literal
// itself), so this file also covers the object-literal edge cases the fix
// had to keep working, including nested-inside-a-class-method and eval().

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- 1. super.x follows a live prototype mutation of the class's own .prototype ---
{
    class base { method() { return "base method"; } }
    class derived extends base {
        testProp() { return super.method(); }
    }
    var instance = new derived();
    check("super.x before mutation", instance.testProp(), "base method");
    class other { method() { return "OTHER method"; } }
    Object.setPrototypeOf(derived.prototype, other.prototype);
    check("super.x after mutation follows the live chain", instance.testProp(), "OTHER method");
}

// --- 2. super[expr] evaluates expr BEFORE resolving the super base, and a
//        null prototype chain (from that evaluation) throws TypeError ---
{
    class base2 { method() {} }
    class derived2 extends base2 {
        testElem() { return super[ruin()]; }
    }
    function ruin() {
        Object.setPrototypeOf(derived2.prototype, null);
        return 5;
    }
    var instance2 = new derived2();
    var threw = false;
    try { instance2.testElem(); } catch (e) { threw = e instanceof TypeError; }
    check("super[expr] with nulled prototype chain throws TypeError", threw, true);
}

// --- 3. object literal super.x: unaffected by an unrelated class super.x fix ---
{
    var literalProto = { toString() { return "literalProto str"; } };
    var obj = { greet() { return super.toString(); } };
    Object.setPrototypeOf(obj, literalProto);
    check("plain object literal super.toString()", obj.greet(), "literalProto str");
}

// --- 4. object literal nested inside a class instance method: must resolve
//        its OWN HomeObject, not the enclosing class's ---
{
    class MyClass {
        toString() { return "MyClass str"; }
        method() {
            var literalProto = { toString() { return "literalProto str"; } };
            var inner = { greet() { return super.toString(); } };
            Object.setPrototypeOf(inner, literalProto);
            return inner.greet();
        }
    }
    check("object literal nested in class method uses its own HomeObject",
        new MyClass().method(), "literalProto str");
}

// --- 5. object literal nested inside a STATIC class method ---
{
    class Base3 { static hi() { return "base hi"; } }
    class Sub3 extends Base3 {
        static method() {
            var literalProto = { toString() { return "proto str"; } };
            var inner = { greet() { return super.toString(); } };
            Object.setPrototypeOf(inner, literalProto);
            return inner.greet();
        }
    }
    check("object literal nested in static class method uses its own HomeObject",
        Sub3.method(), "proto str");
}

// --- 6. eval("super.x") inside an object literal method (direct eval must
//        resolve the SAME binding the surrounding code has, not the class's) ---
{
    var A = { fromA: "a", fromB: "a" };
    var B = { fromB: "b" };
    Object.setPrototypeOf(B, A);
    var fromA, fromB;
    var literalObj = {
        fromA: "c",
        fromB: "c",
        method() {
            fromA = eval("super.fromA;");
            fromB = eval("super.fromB;");
        },
    };
    Object.setPrototypeOf(literalObj, B);
    literalObj.method();
    check("eval(super.x) in object literal method: fromA", fromA, "a");
    check("eval(super.x) in object literal method: fromB", fromB, "b");
}

// --- 7. eval("super.x") inside a class instance method still works ---
{
    class EvalBase {
        greeting() { return "hi from base"; }
    }
    class EvalDerived extends EvalBase {
        method() { return eval("super.greeting()"); }
    }
    check("eval(super.x) in class method", new EvalDerived().method(), "hi from base");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
