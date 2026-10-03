// An identifier in a call's argument list that precedes a callable argument is a reference to
// the enclosing function's local, not a parameter of the callable: the closure must see the
// local's later writes.
var fn;
function keep(a, b) { fn = b; }

(function (k) {
    keep(k, function () { return k; });
    k = 7;
})(5);
if (fn() !== 7) throw new Error("closure over param after call-arg list: got " + fn());

var holder;
function keep2(a, b, o) { holder = o; }
(function (k) {
    keep2(1, k, { get: function () { return k; } });
    k = 8;
})(5);
if (holder.get() !== 8) throw new Error("closure in object literal after call-arg list: got " + holder.get());

(function () {
    var v = 1;
    function run(a, b) { return b(); }
    var r = run(v, function () { return v; });
    v = 9;
    if (r !== 1) throw new Error("sync read: " + r);
    var later = run(v, function () { return v; });
    if (later !== 9) throw new Error("later read: " + later);
})();
console.log("ok");

// An expression-bodied arrow's parameter defaults reference the enclosing function's locals.
(function () {
    var v = 1;
    var f = (x = v) => x;
    v = 2;
    if (f() !== 2) throw new Error("arrow default read of outer local: " + f());
})();
(function () {
    var v = 1;
    var g = ({ a = v } = {}) => a;
    v = 2;
    if (g() !== 2) throw new Error("arrow pattern default read of outer local: " + g());
})();
(function () {
    var v = 1;
    function h({ a = v } = {}) { return a; }
    v = 2;
    if (h() !== 2) throw new Error("function pattern default read of outer local: " + h());
})();
console.log("ok");
