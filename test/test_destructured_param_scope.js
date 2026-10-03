// Destructured parameters bind their leaves like plain ones: an arrow whose
// leaves nothing observes by name runs without a scope, and any observer
// keeps one.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

check("object", (({ a, b }) => a + b)({ a: 1, b: 2 }), 3);
check("array", (([a, b]) => a * b)([3, 4]), 12);
check("nested", (({ p: { q }, r: [s] }) => q + s)({ p: { q: 1 }, r: [2] }), 3);
check("renamed", (({ a: x }) => x)({ a: 7 }), 7);
check("rest element", (([a, ...r]) => a + r.length)([1, 2, 3]), 3);
check("object rest", (({ a, ...o }) => Object.keys(o).join())({ a: 1, b: 2, c: 3 }), "b,c");
check("missing", String((({ a }) => a)({})), "undefined");
check("two params", (({ a }, [b]) => a + b)({ a: 1 }, [2]), 3);
check("mixed", ((x, { y }, ...z) => x + y + z.length)(1, { y: 2 }, 3, 4), 5);
check("map callback", [{ v: 1 }, { v: 2 }].map(({ v }) => v * 2).join(), "2,4");
check("entries", Object.entries({ a: 1, b: 2 }).map(([k, v]) => k + v).join(), "a1,b2");
check("function form", (function ({ a }, [b]) { return a + b; })({ a: 1 }, [2]), 3);

// Defaults inside the pattern, and defaults on the whole pattern.
check("leaf default", (({ a = 5 }) => a)({}), 5);
check("leaf default given", (({ a = 5 }) => a)({ a: 1 }), 1);
check("pattern default", (({ a } = { a: 9 }) => a)(), 9);
check("array default", (([a = 3] = []) => a)(), 3);
check("default sees earlier leaf", (({ a, b = a + 1 }) => b)({ a: 1 }), 2);
check("computed key", (({ ["k" + 1]: v }) => v)({ k1: 4 }), 4);

// Observers.
check("closure", (({ a }) => (() => a)())({ a: 6 }), 6);
check("closure mutates", (([a]) => { var f = () => ++a; f(); return a; })([1]), 2);
check("eval", (({ a }) => eval("a + 1"))({ a: 1 }), 2);
check("with", (({ a }) => { with ({ w: 2 }) { return a + w; } })({ a: 1 }), 3);
check("shadows a global", (function () {
    var a = "outer";
    var r = (({ a }) => a)({ a: "inner" });
    return r + a;
})(), "innerouter");
check("this stays lexical", (function () { return (({ a }) => a + this.k)({ a: 1 }); }).call({ k: 2 }), 3);

// A throwing pattern.
var thrown;
try { (({ a }) => a)(null); } catch (e) { thrown = e.constructor; }
check("null argument", thrown, TypeError);
thrown = undefined;
try { (([a]) => a)(undefined); } catch (e) { thrown = e.constructor; }
check("undefined argument", thrown, TypeError);

var s = 0;
var f = ({ a, b }) => a + b;
for (var i = 0; i < 20000; i++) s = f({ a: i, b: 1 });
check("loop", s, 20000);
print("ok");
