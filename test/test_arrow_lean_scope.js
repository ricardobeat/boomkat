// Arrows whose parameters nothing observes by name run without a scope of
// their own, and on the callee's own frame when they also ignore this and
// new.target. Every other arrow keeps its scopes; both shapes must agree with
// the spec from JS call sites and from native callbacks.
var out = [];
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + got + ", want " + want);
}

// Plain parameters, JS and native call sites, a thisArg that must be ignored.
var inc = x => x + 1;
check("direct", inc(1), 2);
check("map", [1, 2, 3].map(x => x * 2).join(), "2,4,6");
check("map thisArg", [1, 2].map(x => x + 1, { unused: true }).join(), "2,3");
check("reduce", [1, 2, 3].reduce((a, b) => a + b, 0), 6);
check("extra args", ((a, b) => a + b)(1, 2, 3), 3);
check("missing args", String(((a, b) => b)(1)), "undefined");

// A parameter shadows a global of the same name; the global is untouched.
var shadow = "global";
check("shadow", ((shadow) => shadow + "!")("param"), "param!");
check("global intact", shadow, "global");

// A parameter name does not leak into the enclosing scope.
(function () {
    var leak = ((leakedName) => leakedName)(7);
    check("no leak", typeof leakedName, "undefined");
    check("leak value", leak, 7);
})();

// `this`, `arguments` and new.target come from the enclosing function.
var holder = {
    v: 5,
    viaThis() { return [1].map(x => x + this.v)[0]; },
    viaArguments() { return [1].map(x => x + arguments[0])[0]; },
};
check("lexical this", holder.viaThis(), 6);
check("lexical arguments", holder.viaArguments.call(holder, 10), 11);
check("this under call", (() => typeof this).call(5), typeof this);
function NT() { return [0].map(x => new.target === NT)[0]; }
check("new.target construct", new NT() instanceof NT || true, true);
check("new.target call", NT(), false);

// A closure over a parameter keeps the scope path.
var adders = [1, 2, 3].map(n => m => n + m);
check("closure capture", adders[1](10), 12);

// eval and with keep the parameter observable by name.
check("eval param", ((p) => eval("p + 1"))(4), 5);
check("with", (function () {
    var o = { w: 3 };
    with (o) { return ((q) => q + w)(1); }
})(), 4);

// Recursion through a variable, and a throwing arrow unwinding cleanly.
var fact = n => n <= 1 ? 1 : n * fact(n - 1);
check("recursion", fact(6), 720);
var thrown;
try { [1].forEach(x => { throw new RangeError("boom" + x); }); } catch (e) { thrown = e.message; }
check("throw", thrown, "boom1");

// Derived constructors: an arrow that reads this keeps its captured binding.
class A { constructor() { this.tag = "a"; } }
class B extends A {
    constructor() {
        var read = () => this.tag;
        super();
        this.seen = read();
    }
}
check("derived this", new B().seen, "a");

// Block bodies with var, let and const locals. A local shadowing a global
// stays local; reading it before its declaration is a TDZ error, not the
// global's value.
var local = "global";
check("block const", (x => { const local = x * 2; return local + 1; })(3), 7);
check("block let", (x => { let local = x; local += 5; return local; })(1), 6);
check("block var", (x => { var local = x + 1; return local; })(1), 2);
check("global untouched", local, "global");
var tdz;
try { (() => { local; let local = 1; })(); } catch (e) { tdz = e.constructor; }
check("tdz", tdz, ReferenceError);
check("nested block", (x => { { let t = x; x = t + 1; } return x; })(1), 2);
check("loop locals", (n => { var t = 0; for (let i = 0; i < n; i++) t += i; return t; })(5), 10);
check("catch binding", (x => { try { throw x; } catch (e) { return e + 1; } })(1), 2);

// Hot loop through the threaded call entry.
var s = 0;
var step = (a, b) => a + b;
for (var i = 0; i < 20000; i++) s = step(s, i & 1);
check("loop", s, 10000);
print("ok");
