// A catch parameter that no closure, eval or `with` can see by name lives in a
// register; every other one keeps its own scope. Both must agree with the spec.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

check("plain", (function (x) { try { throw x; } catch (e) { return e + 1; } })(1), 2);
check("assign", (function () { try { throw 1; } catch (e) { e = e + 10; return e; } })(), 11);
check("nested", (function () {
    try { throw 1; } catch (e) {
        try { throw e + 1; } catch (e) { return e * 10; }
    }
})(), 20);
check("inner shadows outer", (function () {
    var out = [];
    try { throw "a"; } catch (e) {
        try { throw "b"; } catch (e) { out.push(e); }
        out.push(e);
    }
    return out.join();
})(), "b,a");

// A function-level var of the same name is a separate binding.
check("outer var untouched", (function () {
    var e = "outer";
    try { throw "inner"; } catch (e) { e = "changed"; }
    return e;
})(), "outer");
check("body var assigns the parameter", (function () {
    var seen;
    try { throw 1; } catch (e) { var e = 2; seen = e; }
    return seen;
})(), 2);
check("for-in head", (function () {
    try { throw 1; } catch (e) { for (var e in { k: 1 }) {} return e; }
})(), "k");

// Parameters visible to a closure, eval or with keep their scope.
check("closure", (function () {
    var f; try { throw 7; } catch (e) { f = function () { return e; }; }
    return f();
})(), 7);
check("closure mutation", (function () {
    var f; try { throw 1; } catch (e) { f = () => ++e; f(); return e; }
})(), 2);
check("eval", (function () { try { throw 3; } catch (e) { return eval("e + 1"); } })(), 4);
check("with reads", (function () {
    try { throw 5; } catch (e) { with ({ w: 1 }) { return e + w; } }
})(), 6);
check("with writes", (function () {
    try { throw 5; } catch (e) { with ({ w: 1 }) { e = 9; } return e; }
})(), 9);
check("with object shadows", (function () {
    try { throw 5; } catch (e) { with ({ e: 1 }) { return e; } }
})(), 1);
check("typeof", (function () { try { throw 1; } catch (e) { return typeof e; } })(), "number");
check("tdz-free after", (function () { try { throw 1; } catch (e) {} return typeof e; })(), "undefined");

// Rethrow, finally, return from catch, loops, generators, async.
check("rethrow", (function () {
    try { try { throw 1; } catch (e) { throw e + 1; } } catch (f) { return f; }
})(), 2);
check("finally", (function () {
    var log = [];
    try { try { throw 1; } catch (e) { log.push(e); return log.join(); } finally { log.push("f"); } } finally { log.push("g"); }
})(), "1");
check("loop", (function () {
    var s = 0;
    for (var i = 0; i < 5; i++) { try { throw i; } catch (e) { s += e; } }
    return s;
})(), 10);
check("generator", (function () {
    function* g() { try { throw 1; } catch (e) { yield e; yield e + 1; } }
    return Array.from(g()).join();
})(), "1,2");
check("arrow", (x => { try { throw x; } catch (e) { return e * 2; } })(4), 8);
check("native error", (function () {
    try { null.x; } catch (e) { return e instanceof TypeError; }
})(), true);
check("destructured", (function () {
    try { throw { a: 1 }; } catch ({ a }) { return a; }
})(), 1);

var s = 0;
function hot(x) { try { if (x > 100) throw x; return x + 1; } catch (e) { return e; } }
for (var i = 0; i < 20000; i++) s += hot(i & 7);
check("loop total", s, 90000);
print("ok");
