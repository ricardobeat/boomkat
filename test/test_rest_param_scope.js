// A rest parameter nothing observes by name needs no scope of its own. Every
// observer (closure, eval, with, arguments) keeps it, and the array contents
// must not depend on which path the call took.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

function len(...r) { return r.length; }
check("none", len(), 0);
check("some", len(1, 2, 3), 3);
check("undefined counts", len(undefined, undefined), 2);
function lead(a, b, ...r) { return [a, b, r.length].join(); }
check("fewer than formals", lead(1), "1,,0");
check("exact", lead(1, 2), "1,2,0");
check("overflow", lead(1, 2, 3, 4), "1,2,2");
check("rest is an array", (function (...r) { return Array.isArray(r) && r.length === 2; })(1, 2), true);
check("rest is fresh", (function (...r) { return r; })() !== (function (...r) { return r; })(), true);
check("rest values", (function (...r) { return r.join(); })("a", { toString() { return "o"; } }, 3), "a,o,3");

// Arrows, methods, constructors, generators, async.
check("arrow", ((...r) => r.length)(1, 2), 2);
check("arrow with leading", ((a, ...r) => a + r.length)(10, 1, 2), 12);
check("arrow this", (function () { return ((...r) => this.k + r.length)(1); }).call({ k: 5 }), 6);
check("method", ({ m(...r) { return r.length; } }).m(1, 2, 3), 3);
class C { constructor(...r) { this.n = r.length; } static s(...r) { return r.length; } }
check("ctor", new C(1, 2).n, 2);
check("static", C.s(1), 1);
check("generator", Array.from((function* (...r) { yield* r; })(1, 2)).join(), "1,2");
check("map callback", [1, 2].map((...r) => r.length).join(), "3,3");

// Observers.
check("closure", (function (...r) { return (() => r.length)(); })(1, 2), 2);
check("closure mutates", (function (...r) { var f = () => r.push(9); f(); return r.length; })(1), 2);
check("eval", (function (...r) { return eval("r.length"); })(1, 2, 3), 3);
check("with", (function (...r) { with ({}) { return r.length; } })(1, 2), 2);
check("arguments", (function (...r) { return arguments.length + r.length; })(1, 2), 4);
check("default plus rest", (function (a = 1, ...r) { return a + r.length; })(undefined, 1, 2), 3);
check("destructured rest", (function (...[a, b]) { return a + b; })(1, 2), 3);
check("name shadows a global", (function (undefinedName, ...len) { return len.length; })(1, 2, 3), 2);

// Calls through native code, bind, apply, spread.
check("apply", len.apply(null, [1, 2, 3]), 3);
check("call", len.call(null, 1), 1);
check("bind", len.bind(null, 1, 2)(3), 3);
check("spread", len(...[1, 2, 3, 4]), 4);
check("reflect", Reflect.apply(len, null, [1, 2]), 2);
check("recursion", (function f(n, ...r) { return n === 0 ? r.length : f(n - 1, ...r, n); })(50), 50);

var s = 0;
for (var i = 0; i < 20000; i++) s += len(i, i);
check("loop", s, 40000);
print("ok");
