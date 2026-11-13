// Method calls of builtins from native code (vm::jit_call_builtin_method): a
// value result, a throw caught in the caller, re-dispatching builtins (call,
// apply, a generator's next), callbacks into script that grow the value stack,
// and a callee that stops being a builtin.
var out = [];

function values(n) {
    var s = "abcabcabc", t = 0;
    for (var i = 0; i < n; i++) t += s.indexOf("c", i % 9) + s.lastIndexOf("a");
    return t;
}
out.push(values(3000));

function throws(n) {
    var caught = 0, last = "";
    for (var i = 0; i < n; i++) {
        try { "x".repeat(i % 50 === 7 ? -1 : 2); } catch (e) { caught++; last = e.name; }
    }
    return caught + ":" + last;
}
out.push(throws(3000));

function add(a, b) { return this.base + a + b; }
function redispatch(n) {
    var o = { base: 10 }, t = 0;
    for (var i = 0; i < n; i++) t += add.call(o, i, 1) + add.apply(o, [i, 2]);
    return t;
}
out.push(redispatch(3000));

function* counter() { var i = 0; for (;;) yield i++; }
function resumes(n) {
    var g = counter(), t = 0;
    for (var i = 0; i < n; i++) t += g.next().value;
    return t;
}
out.push(resumes(3000));

function depth(k) { return k === 0 ? 0 : 1 + depth(k - 1); }
function callbacks(n) {
    var a = [1, 2, 3], t = 0;
    for (var i = 0; i < n; i++) {
        t += a.map(function (x) { return x + depth(i % 40); }).length;
        t += "a-b-c".replace(/-/g, function () { return depth(5); }).length;
    }
    return t;
}
out.push(callbacks(2000));

// The site's callee turns into a script function and back.
function swap(n) {
    var s = "hello", t = 0;
    for (var i = 0; i < n; i++) {
        if (i === 1500) String.prototype.indexOf = function (c) { return 100; };
        t += s.indexOf("l");
    }
    return t;
}
var indexOf = String.prototype.indexOf;
out.push(swap(3000));
String.prototype.indexOf = indexOf;
out.push(swap(1000));
console.log(out.join(" "));
