// Builtins called as plain functions (CALL_UNDEF_THIS): the receiver is undefined whatever the
// register below the arguments held, so a builtin that needs a `this` throws, and one that takes
// none runs as a method call would. A hot aliased Math function becomes a MATH node in optimized
// code and must notice when the alias changes.
var out = [];
function show(label, v) { out.push(label + "=" + v); }

function tryCall(f, arg) {
    try { return "ok " + f(arg); } catch (e) { return e.constructor.name; }
}
var charCodeAt = String.prototype.charCodeAt;
var push = Array.prototype.push;
var toFixed = Number.prototype.toFixed;
var isArray = Array.isArray;
var sloppyThis = function () { return this === undefined ? "undef" : typeof this; };
var strictThis = function () { "use strict"; return this === undefined ? "undef" : typeof this; };
var r = [];
for (var k = 0; k < 300; k++) {
    var o = { s: "receiver" };
    // The register under the arguments holds an object just before each call.
    r = [tryCall(charCodeAt, 0), tryCall(push, 1), tryCall(toFixed, 2), tryCall(isArray, [o]),
         tryCall(parseInt, "42px"), tryCall(String, o.s), tryCall(sloppyThis), tryCall(strictThis)];
}
show("this", r.join(","));

function hyp(n, sqrt, floor) {
    var s = 0;
    for (var i = 1; i <= n; i++) {
        var a = i * 0.5, b = i * 1.25;
        s += sqrt(a * a + b * b) + floor(a);
    }
    return s;
}
var t = 0;
for (var k = 0; k < 200; k++) t = hyp(400, Math.sqrt, Math.floor);
show("hyp", t);
show("swapped", hyp(400, Math.cbrt, Math.ceil));
show("custom", hyp(10, function (x) { return x; }, Math.round));
show("back", hyp(400, Math.sqrt, Math.floor));

// A plain call whose builtin throws, caught in the caller.
function bad(n) {
    var caught = 0, f = BigInt;
    for (var i = 0; i < n; i++) {
        try { f(1.5); } catch (e) { caught += e instanceof RangeError ? 1 : 100; }
    }
    return caught;
}
show("throws", bad(300));
console.log(out.join("\n"));
