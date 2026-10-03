// An arrow that creates closures drops its scope when no closure reads one of
// its names. Every closure that does read one must still find it, however the
// binding was declared and however late the closure runs.
function check(label, got, want) {
    if (got !== want) throw new Error(label + ": got " + String(got) + ", want " + String(want));
}

check("unrelated closure", ((x) => [x].map((y) => y + 1)[0])(1), 2);
check("closure reads param", ((x) => (() => x)())(4), 4);
check("closure reads late", ((x) => { var f = () => x; return f; })(5)(), 5);
check("closure reads local", ((x) => { var y = x * 2; return () => y; })(3)(), 6);
check("closure reads let", ((x) => { let y = x * 2; return () => y; })(3)(), 6);
check("closure reads const", ((x) => { const y = x * 2; return () => y; })(3)(), 6);
check("closure writes", ((x) => { var f = () => ++x; f(); f(); return x; })(1), 3);
check("each call gets its own", (function () {
    var make = (n) => () => n;
    var a = make(1), b = make(2);
    return a() * 10 + b();
})(), 12);
check("nested arrows", ((a) => (b) => (c) => a + b + c)(1)(2)(3), 6);
check("middle arrow unused", ((a) => (b) => () => a)(7)(8)(), 7);
check("closure over outer function var", (function () {
    var v = 9;
    return ((x) => [x].map((y) => y + v)[0])(1);
})(), 10);
check("closure over outer arrow param", ((o) => ((x) => [x].map((y) => y + o)[0])(1))(5), 6);
check("sibling closures", ((x) => { var f = () => x; var g = () => 0; return f() + g(); })(2), 2);
check("closure in default", ((x, y = () => x) => y())(3), 3);
check("closure in destructure default", (({ a }, b = () => a) => b())({ a: 8 }), 8);
check("rest and closure", ((...r) => (() => r.length)())(1, 2), 2);
check("this in nested arrow", (function () { return ((x) => (() => this.k + x)())(1); }).call({ k: 4 }), 5);
check("arguments in nested arrow", (function () { return ((x) => (() => arguments[0] + x)())(1); })(6), 7);
check("closure in loop", ((n) => {
    var fs = [];
    for (let i = 0; i < n; i++) fs.push(() => i);
    return fs.map((f) => f()).join();
})(3), "0,1,2");
check("closure in block", ((x) => { { let z = x + 1; return () => z; } })(1)(), 2);
check("callback keeps arrow local", ((x) => [1, 2].map((y) => { var t = x + y; return t; }).join())(10), "11,12");
check("function declaration inside", ((x) => { function g() { return x; } return g(); })(5), 5);
check("function declaration unrelated", ((x) => { function g() { return 1; } return g() + x; })(5), 6);
check("class inside", ((x) => { class K { m() { return x; } } return new K().m(); })(5), 5);
check("class unrelated", ((x) => { class K { m() { return 1; } } return new K().m() + x; })(5), 6);
check("generator inside", ((x) => { function* g() { yield x; } return g().next().value; })(5), 5);
check("eval sees param", ((x) => { var f = () => 1; return f() + eval("x"); })(5), 6);
check("shadowing", ((x) => { var f = (x) => x; return f(1) + x; })(10), 11);
check("shadowing by var", ((x) => { var f = () => { var x = 1; return x; }; return f() + x; })(10), 11);
check("global named like a param", (function () {
    globalThis.gx = "global";
    var r = ((gx) => [1].map(() => 0)[0] + gx)("param");
    return r;
})(), "0param");
check("recursion", (function () {
    var fact = (n) => n <= 1 ? 1 : n * [n - 1].map((m) => fact(m))[0];
    return fact(5);
})(), 120);
check("closure survives gc", (function () {
    var f = ((x) => { var arr = [x]; return () => arr[0]; })(42);
    for (var i = 0; i < 20000; i++) ({ i: i });
    return f();
})(), 42);

// try/catch and switch with closures inside an arrow.
check("catch param captured", ((x) => { try { throw x; } catch (e) { return (() => e)(); } })(3), 3);
check("catch param unrelated closure", ((x) => { try { throw x; } catch (e) { return [e].map((v) => v)[0]; } })(3), 3);
check("switch lexical", ((x) => { switch (x) { case 1: { let q = 5; return (() => q)(); } } })(1), 5);
print("ok");
