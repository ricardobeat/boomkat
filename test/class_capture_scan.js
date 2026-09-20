// pre_scan_captures degrades to capture_all for a class only when the class
// body has a field initializer. A field initializer runs in constructor scope
// and can name an outer local with no `) {` for the scanner's region tracking
// to see, so it is the one class form that defeats the per-name capture set.
// Methods are ordinary callable bodies the `) {` rule already covers, so a
// method-only class must leave the enclosing locals in registers.
//
// A missed capture is a wrong value, not a slow one: the outer local stays in
// a register while the class body reads it through the env chain and finds a
// stale or absent binding. Every case below therefore asserts the value an
// outer binding must carry into a class body.

function assertEqual(actual, expected, label) {
    if (actual !== expected) throw new Error(label + ": " + actual + " !== " + expected);
}

// Field initializer reading an outer local: the degrade case.
function fieldInit() {
    var outer = 7;
    class C { x = outer; }
    return new C().x;
}
assertEqual(fieldInit(), 7, "field initializer reads outer local");

// The same, with the outer local reassigned after the class declaration.
// Field initializers run at construction, so the later value is the live one.
function fieldInitLate() {
    var outer = 1;
    class C { x = outer; }
    outer = 2;
    return new C().x;
}
assertEqual(fieldInitLate(), 2, "field initializer reads outer local at construction");

// Static field initializers run at class definition time, still in a scope
// that reaches outer locals.
function staticField() {
    var outer = 5;
    class C { static x = outer; }
    return C.x;
}
assertEqual(staticField(), 5, "static field initializer reads outer local");

// Computed keys evaluate in the enclosing scope, not constructor scope, but
// must still resolve the outer binding correctly.
function computedKey() {
    var key = "k";
    class C { [key]() { return 3; } }
    return new C().k();
}
assertEqual(computedKey(), 3, "computed method key reads outer local");

// A method closing over an outer local: covered by `) {`, so no degrade is
// needed, but the capture must still happen.
function methodCapture() {
    var outer = 11;
    class C { m() { return outer; } }
    return new C().m();
}
assertEqual(methodCapture(), 11, "method closes over outer local");

// A method parameter default reading an outer local sits inside the parens the
// param buffer handles, so it must capture without the class degrade.
function paramDefault() {
    var outer = 13;
    class C { m(a = outer) { return a; } }
    return new C().m();
}
assertEqual(paramDefault(), 13, "method param default reads outer local");

// `=` inside a method body is deeper than the class body, so it must not be
// mistaken for a field initializer. The outer local is still captured because
// the method body is a tracked callable region.
function assignInMethod() {
    var outer = 17;
    class C { m() { var local = outer; return local; } }
    return new C().m();
}
assertEqual(assignInMethod(), 17, "assignment inside method body");

// A class nested inside a method, with the field initializer on the inner one.
// The degrade must follow the inner class body's depth, not the outer one's.
function nestedClassField() {
    var outer = 19;
    class Outer {
        m() {
            class Inner { x = outer; }
            return new Inner().x;
        }
    }
    return new Outer().m();
}
assertEqual(nestedClassField(), 19, "field initializer in a nested class");

// A class expression in argument position: the body brace still has to be
// matched to the `class` token that armed the watch.
function classExpr() {
    var outer = 23;
    var C = (class { x = outer; });
    return new C().x;
}
assertEqual(classExpr(), 23, "class expression field initializer");

// `extends` puts tokens between `class` and its body brace; the first `{`
// after them is still the class body.
function classExtends() {
    var outer = 29;
    class Base {}
    class C extends Base { x = outer; }
    return new C().x;
}
assertEqual(classExtends(), 29, "field initializer with extends clause");

// A field initializer whose expression itself contains braces (an object
// literal) must not close the class body early.
function fieldObjectLiteral() {
    var outer = 31;
    class C { x = { v: outer }; }
    return new C().x.v;
}
assertEqual(fieldObjectLiteral(), 31, "field initializer holding an object literal");

// The performance shape this change exists for: a method-only class beside a
// `let` loop. The loop variable and the accumulator must stay correct once
// they are left in registers.
function methodOnlyLoop() {
    class C { m() { return 2; } }
    var c = new C();
    var s = 0;
    for (let i = 0; i < 4; i++) { s += c.m() + i; }
    return s;
}
assertEqual(methodOnlyLoop(), 14, "method-only class beside a let loop");

// A closure created in that same loop must still see its own per-iteration
// binding, which is the part that depends on the loop env surviving.
function perIterationCapture() {
    class C { m() { return 0; } }
    var c = new C();
    var fns = [];
    for (let i = 0; i < 3; i++) { fns.push(function () { return i + c.m(); }); }
    return fns[0]() + "," + fns[1]() + "," + fns[2]();
}
assertEqual(perIterationCapture(), "0,1,2", "per-iteration binding with a method-only class");

print("class capture scan ok");
