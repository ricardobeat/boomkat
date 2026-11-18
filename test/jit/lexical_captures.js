// Closures that read a let, const or class of the enclosing function across a class or block scope,
// warmed past the compile threshold: the binding changing after the reads compiled, a closure made
// before its binding was initialized (TDZ) while a farther binding of the name exists, a block
// function hoisted after the closure, and a sloppy direct eval that declares the name nearer.
var out = [];
var x = "far-x";
(function () {
    const CT = "ct";
    let L = 1;
    class Holder {
        static get() { return CT + L; }
        m() { return CT; }
    }
    for (let i = 0; i < 3000; i++) Holder.get();
    out.push(Holder.get());
    L = 2;
    out.push(Holder.get(), new Holder().m());
    {
        const early = () => x;
        try { early(); out.push("no tdz"); } catch (e) { out.push(e.constructor.name); }
        const x = "near-x";
        for (let i = 0; i < 3000; i++) early();
        out.push(early());
    }
    {
        const k = () => { class Q { static r() { return CT; } } return Q.r(); };
        for (let i = 0; i < 3000; i++) k();
        out.push(k());
    }
    {
        const f = () => CT;
        out.push(typeof f());
        function CT() { return 1; }
        for (let i = 0; i < 3000; i++) f();
        out.push(typeof f());
    }
    class Before { static r() { return LATER; } }
    for (let n = 0; n < 3000; n++) {
        try { Before.r(); } catch (e) { if (n === 0) out.push(e.constructor.name); }
    }
    let LATER = 5;
    for (let i = 0; i < 3000; i++) Before.r();
    out.push(Before.r());
    class K {}
    class U { static r() { return K; } }
    for (let i = 0; i < 3000; i++) U.r();
    out.push(U.r() === K);
})();
(function () {
    const v = "outer";
    function g(code) {
        eval(code);
        { class C { static r() { return v; } } return C.r(); }
    }
    for (let i = 0; i < 3000; i++) g("");
    out.push(g(""), g("var v = 'shadow'"));
})();
var expected = "ct1,ct2,ct,ReferenceError,near-x,ct,function,function,ReferenceError,5,true,outer,shadow";
if (out.join(",") !== expected) throw new Error("got " + out.join(","));
print(out.join(","));
