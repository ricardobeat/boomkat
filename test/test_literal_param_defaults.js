// A parameter default that is a lone literal loads in the prologue without a
// thunk closure, and a function whose defaults are all literals drops its
// parameter scopes when nothing observes them.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

function lits(a = 1, b = "s", c = null, d = true, e = false, f = 2.5, g = -3, h = 1n) {
    return [a, b, c, d, e, f, g, h].map(String).join();
}
check("all defaults", lits(), "1,s,null,true,false,2.5,-3,1");
check("undefined takes default", lits(undefined, undefined), "1,s,null,true,false,2.5,-3,1");
check("null does not", lits(null, 0, 0, 0, 0, 0, 0, 0), "null,0,0,0,0,0,0,0");
check("length", lits.length, 0);
check("length after plain", (function (a, b = 1, c) {}).length, 1);

// Fresh object and array per call.
function fresh(o = {}, a = []) { o.n = (o.n | 0) + 1; a.push(1); return [o.n, a.length]; }
check("fresh o", fresh()[0], 1);
check("fresh again", fresh()[0], 1);
check("fresh array", fresh()[1], 1);
var shared = {};
fresh(shared); fresh(shared);
check("passed object", shared.n, 2);

// Parameters stay distinct from a global of the same name and from body vars.
var g1 = "global";
function shadow(g1 = "param") { var inner = g1 + "!"; return inner; }
check("shadow", shadow(), "param!");
check("global intact", g1, "global");
function bodyVar(x = 1) { var x; return x; }
check("redeclared param keeps value", bodyVar(), 1);
check("redeclared param given", bodyVar(5), 5);

// Later parameters, arrows, methods, class constructors.
check("middle default", (function (a, b = 2, c) { return [a, b, c].join(); })(1, undefined, 3), "1,2,3");
check("arrow", ((x, y = 10) => x + y)(1), 11);
check("arrow undefined", ((x, y = 10) => x + y)(1, undefined), 11);
check("arrow given", ((x, y = 10) => x + y)(1, 2), 3);
var obj = { m(a = "m") { return a + this.k; }, k: 1 };
check("method this", obj.m(), "m1");
class C { constructor(v = 7) { this.v = v; } static s(a = 4) { return a; } }
check("ctor", new C().v, 7);
check("static", C.s(), 4);
check("map callback", [1, 2].map((x, i = 100) => x + i).join(), "1,3");

// Observers keep the parameter scope.
check("closure", (function (a = 1) { return (() => a)(); })(), 1);
check("closure mutates", (function (a = 1) { var f = () => ++a; f(); return a; })(), 2);
check("eval", (function (a = 1) { return eval("a + 1"); })(), 2);
check("with", (function (a = 1) { with ({ w: 5 }) { return a + w; } })(), 6);
check("arguments", (function (a = 1) { arguments[0] = 9; return a; })(), 1);
check("arguments length", (function (a = 1) { return arguments.length; })(), 0);
check("rest", (function (a = 1, ...r) { return a + r.length; })(undefined, 1, 2), 3);

// A default that is not a lone literal still runs as an expression.
var calls = 0;
function exprDefault(a = (calls++, 1), b = a + 1) { return [a, b].join(); }
check("expr", exprDefault(), "1,2");
check("expr side effect", calls, 1);
check("expr given", exprDefault(5), "5,6");
check("expr given side effect", calls, 1);
check("tdz", (function () { try { (function (a = b, b = 1) {})(); } catch (e) { return e.constructor === ReferenceError; } })(), true);

var s = 0;
function hot(x, d = 1) { return x + d; }
for (var i = 0; i < 20000; i++) s = hot(s);
check("loop", s, 20000);
print("ok");
