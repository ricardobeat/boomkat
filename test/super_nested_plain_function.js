// super.x / super() / super[x] are only syntactically valid in the function
// that DIRECTLY has a [[HomeObject]]/[[Super]] binding, per spec ES2022
// §13.3.7.1's HasSuperBinding check. A plain (non-arrow) `function`
// expression or declaration creates a fresh binding boundary, even when
// written lexically inside a class method or constructor -- unlike an arrow
// function, which shares the enclosing one. compile_inner_function used to
// propagate the enclosing method's super/class-body context into EVERY
// nested function body it compiled, plain functions included, so
// `super.x`/`super()` were wrongly accepted (and eval('super.x') inside such
// a nested function wrongly resolved instead of throwing SyntaxError).

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- 1. super.x directly inside a plain function nested in an object-literal method ---
{
    var threw = false;
    try {
        eval(
            "var obj1 = { method: function () {" +
            "  function foo() { return super.toString; }" +
            "  return foo();" +
            "} };"
        );
    } catch (e) {
        threw = e instanceof SyntaxError;
    }
    check("super.x in a plain function nested in a method is a SyntaxError", threw, true);
}

// --- 2. super() directly inside a plain function nested in a derived constructor ---
{
    var threw = false;
    try {
        eval(
            "class Base1 {}" +
            "class Derived1 extends Base1 {" +
            "  constructor() {" +
            "    function foo() { super(); }" +
            "    foo();" +
            "  }" +
            "}"
        );
    } catch (e) {
        threw = e instanceof SyntaxError;
    }
    check("super() in a plain function nested in a constructor is a SyntaxError", threw, true);
}

// --- 3. eval("super.x") inside a plain function nested in a method ---
{
    var threw = false;
    try {
        ({
            method() {
                (function () {
                    eval("super.toString");
                })();
            },
        }).method();
    } catch (e) {
        threw = e instanceof SyntaxError;
    }
    check("eval(super.x) inside a plain nested function is a SyntaxError", threw, true);
}

// --- 4. sanity: a plain function nested in a method is still an ordinary
//        constructible function (is_constructable must not have been
//        wrongly reset to false along with the super-context fields) ---
{
    var obj = {
        method: function () {
            function Foo() {
                this.tag = "made";
            }
            return new Foo();
        },
    };
    var made = obj.method();
    check("plain function nested in a method is still constructible", made.tag, "made");
}

// --- 5. sanity: an arrow function nested in a method DOES still inherit
//        super (arrows share the enclosing HomeObject, unaffected by this fix) ---
{
    var literalProto = { toString() { return "literalProto str"; } };
    var obj2 = {
        greet() {
            var inner = () => super.toString();
            return inner();
        },
    };
    Object.setPrototypeOf(obj2, literalProto);
    check("arrow function nested in a method still inherits super", obj2.greet(), "literalProto str");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
