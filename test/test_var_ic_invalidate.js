// A variable read cached against a function's eval-declared binding survives
// the bindings object growing and losing the property.
function assertEq(a, b, msg) {
    if (a !== b) throw new Error(msg + ": expected " + b + ", got " + a);
}

var outer = "outer";
function run() {
    eval("var a = 1");
    var read = function () { return a; };
    var seen = [];
    for (var i = 0; i < 4; i++) seen.push(read());
    assertEq(seen.join(","), "1,1,1,1", "initial reads");

    // Enough new bindings to move the storage the cached slot points into.
    var src = "";
    for (var j = 0; j < 40; j++) src += "var grow" + j + " = " + j + ";";
    eval(src);
    a = 7;
    assertEq(read(), 7, "read after growth");
    assertEq(grow39, 39, "grown binding");

    for (var k = 0; k < 3; k++) assertEq(read(), 7, "repeat read");
    assertEq(eval("delete a"), true, "delete eval var");
    var threw = false;
    try { read(); } catch (e) { threw = e instanceof ReferenceError; }
    assertEq(threw, true, "read of a deleted binding throws");

    eval("var a = 'again'");
    assertEq(read(), "again", "redeclared binding");
}
run();

// A fresh activation of the same code binds its own environment.
function counter() {
    eval("var n = 0");
    return function () { return ++n; };
}
var c1 = counter(), c2 = counter();
for (var m = 0; m < 3; m++) { c1(); }
assertEq(c1(), 4, "first counter");
assertEq(c2(), 1, "second counter");
print("ok");
