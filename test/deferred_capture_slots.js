// A deferred function reads its parent's captured variables through capture
// slots. The slots are laid out when the parent is compiled, before the body
// is, so closures made earlier and names the body shadows must still work.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function basic() {
    var a = 1, b = 2;
    function sum() { return a + b; }
    var first = sum();
    a = 10;
    return first + ":" + sum();
}
check("reads see later writes", basic(), "3:12");

function manyClosures() {
    var fns = [];
    for (var i = 0; i < 3; i++) {
        fns.push((function (k) {
            var local = k * 10;
            function get() { return local + k; }
            return get;
        })(i));
    }
    // All three closures exist before any `get` body is compiled.
    return fns[0]() + "," + fns[1]() + "," + fns[2]();
}
check("closures made before the body is compiled", manyClosures(), "0,11,22");

function shadowing() {
    var x = "outer", y = "outer-y";
    function own() { var x = "inner"; return x + "/" + y; }
    function param(x) { return x + "/" + y; }
    function later() { var r = typeof x; var x = 1; return r + "/" + y; }
    function user() { return x; }
    return [own(), param("p"), later(), user()].join(" ");
}
check("a name the body declares is not a capture", shadowing(), "inner/outer-y p/outer-y undefined/outer-y outer");

function writes() {
    var count = 0, step = 2;
    function inc() { count += step; return count; }
    function setStep(s) { step = s; }
    inc(); setStep(5); inc();
    return count;
}
check("writes reach the parent", writes(), 7);

function dynamic() {
    var v = "plain";
    function viaEval() { return eval("v"); }
    function viaWith(o) { with (o) { return v; } }
    function args() { return arguments.length + v; }
    return [viaEval(), viaWith({}), viaWith({ v: "with" }), args(1, 2)].join(" ");
}
check("eval, with and arguments in the body", dynamic(), "plain plain with 2plain");

function tdz() {
    function early() { return late; }
    try { early(); return "no throw"; } catch (e) { var name = e.name; }
    let late = "ok";
    return name + ":" + early();
}
check("a let read before and after its declaration", tdz(), "ReferenceError:ok");

function nested() {
    var total = 0;
    function mid(k) {
        var local = k;
        function leaf() { total += local; }
        leaf(); leaf();
    }
    for (var i = 0; i < 4; i++) mid(i);
    return total;
}
check("two levels of deferred closures", nested(), 12);

function hoisted() {
    function read() { return typeof later + ":" + v; }
    var before = read();
    var v = 1;
    function later() {}
    return before + " " + read();
}
check("hoisted names", hoisted(), "function:undefined function:1");

if (failures > 0) throw new Error(failures + " check(s) failed");
print("deferred capture slots: OK");
