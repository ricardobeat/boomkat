// A function whose child is compiled on its first call keeps a captured
// variable in a cell when the child reaches it only by plain reads and writes
// of its own. Every other way of reaching the name has to keep working, and
// each form of access to a cell has to find the cell.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// ---- each access form ----
function update() {
    var c = 0;
    return function () { return [++c, c++, c, --c, c--, c, c += 5, c -= 1, c *= 2].join(); };
}
check("updates and compound assignment", update()(), "1,1,2,1,1,0,5,4,8");

function updateValue() { var c = 0; return function () { var r = ++c; return r + (c++) + c; }; }
check("update results", updateValue()(), 4);

function probes() {
    var c = 5, f = function () { return 7; };
    return function () { return [typeof c, typeof f, f(), delete c, c].join(); };
}
check("typeof, call and delete", probes()(), "number,function,7,false,5");

function patterns() {
    var c = 1;
    return function () {
        var k;
        for (c in { z: 1 }) {}
        [k, c] = [1, c + "!"];
        ({ c } = { c: c + "?" });
        return c;
    };
}
check("loop head and destructuring targets", patterns()(), "z!?");

function strictWrite() { var c = 1; return function () { "use strict"; c = 2; c += 1; return c; }; }
check("strict writes", strictWrite()(), 3);

function lexical() {
    let c = 1;
    const k = 2;
    return [function () { c += k; return c; }, function () { return c; }];
}
var pair = lexical();
check("let and const", pair[0]() + pair[1](), 6);

function parameter(p) { return [function () { p = p + 1; }, function () { return p; }]; }
pair = parameter(5);
pair[0]();
check("a parameter", pair[1](), 6);

function declaredLater() { return [function () { return u; }, function () { u = 3; }]; var u; }
pair = declaredLater();
pair[1]();
check("a variable declared after its readers", pair[0](), 3);

// ---- siblings share the binding ----
function shared() {
    var c = 1;
    function get() { return c; }
    return [function () { c = get() + 1; return c; }, get];
}
pair = shared();
check("siblings share a cell", pair[0]() + pair[1](), 4);

function perIteration() {
    var fs = [];
    for (let i = 0; i < 3; i++) fs.push(function () { return i++; });
    return fs;
}
pair = perIteration();
check("a binding per iteration", [pair[0](), pair[0](), pair[2]()].join(), "0,1,2");

// ---- names the child reaches some other way ----
function shadowedByParameter() { var c = 1; return [function (c) { c = 5; return c; }, function () { return c; }]; }
pair = shadowedByParameter();
check("shadowed by a parameter", pair[0](2) + pair[1](), 6);

function shadowedByCatch() {
    var c = 1;
    return [function () { try { throw 7; } catch (c) { c++; return c; } }, function () { return c; }];
}
pair = shadowedByCatch();
check("shadowed by a catch parameter", pair[0]() + pair[1](), 9);

function shadowedByBlock() {
    var c = 1;
    return [function () { { let c = 9; var g = function () { return c; }; c++; } return g() + c; },
            function () { c = 3; }];
}
pair = shadowedByBlock();
pair[1]();
check("shadowed by a block binding", pair[0](), 13);

function shadowedByVar() {
    var c = 1;
    return [function () { var c = 2; return c; }, function () { c = 4; return c; }];
}
pair = shadowedByVar();
check("shadowed by a var", pair[0]() + pair[1](), 6);

function nested() {
    var c = 1;
    return [function () { return function () { return function () { return ++c; }; }; }, function () { return c; }];
}
pair = nested();
pair[0]()()();
check("reached from a nested function", pair[1](), 2);

function defaults() {
    var c = 1;
    return [function (a = c) { return a + c; }, function () { var g = (x = c) => x + c; return g(); },
            function () { c = 4; }];
}
pair = defaults();
pair[2]();
check("parameter defaults", pair[0]() + pair[1](), 16);

function classBody() {
    var c = 1;
    return [function () { class K { m() { return c; } static v = c; } return new K().m() + K.v; },
            function () { c = 4; }];
}
pair = classBody();
pair[1]();
check("reached from a class body", pair[0](), 8);

function withArguments() { var c = 1; return function () { return arguments.length + c; }; }
check("a body that names arguments", withArguments()(0, 0), 3);

function withEval() { var c = 1; return [function () { return eval("c"); }, function () { c = 4; }]; }
pair = withEval();
pair[1]();
check("a body with a direct eval", pair[0](), 4);

function generators() {
    var c = 1;
    return [function* () { yield c; c = 2; yield c; }, function () { return c; }];
}
pair = generators();
var it = pair[0]();
check("a generator", [it.next().value, it.next().value, pair[1]()].join(), "1,2,2");

// ---- a `with` around a deferred function still scopes its names ----
var scope = { x: "with-x" };
var x = "global-x";
with (scope) {
    var read = function () { return x; };
    var write = function () { "use strict"; x = "set"; };
}
write();
check("with scopes a read", read(), "set");
delete scope.x;
check("the name falls through once deleted", read(), "global-x");

var env = { binding: 0, get [Symbol.unscopables]() { delete env.binding; return null; } };
with (env) {
    var strictStore = function () { "use strict"; binding = 123; };
}
var thrown = "none";
try { strictStore(); } catch (e) { thrown = e.name; }
check("a strict store to a binding deleted under it", thrown, "ReferenceError");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred capture cells: OK");
