// ES2024 §10.2.11 FunctionDeclarationInstantiation: every FunctionDeclaration
// of a name is instantiated ONCE, before the first statement runs, and the
// LAST declaration is the one bound. The binding is never re-instantiated
// partway through the scope, so a property set between two declarations
// survives and a call placed before them already sees the final body.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

// The last declaration wins, at every read point in the scope.
function d1() {
    var before = g();
    function g() { return 1; }
    var mid = g();
    function g() { return 2; }
    return [before, mid, g()].join(",");
}
ck("last-decl-wins", d1(), "2,2,2");

// A property set BETWEEN two declarations lands on the one surviving object,
// so the later declaration must not rebind a fresh one.
function d2() {
    function g() { return 1; }
    g.tag = "kept";
    function g() { return 2; }
    return g() + ":" + g.tag;
}
ck("prop-between-decls", d2(), "2:kept");

// A property set after ALL declarations survives.
function d3() {
    function g() { return 1; }
    function g() { return 2; }
    g.tag = "late";
    return g() + ":" + g.tag;
}
ck("prop-after-decls", d3(), "2:late");

// Three declarations: still exactly one binding, still the last body, and
// properties set between any of them survive.
function d4() {
    function g() { return 1; }
    g.a = 1;
    function g() { return 2; }
    g.b = 2;
    function g() { return 3; }
    return [g(), g.a, g.b].join(",");
}
ck("triple-decl", d4(), "3,1,2");

// The same rules at global scope, where a separate hoisting path applies.
var g_before = gg();
function gg() { return 1; }
gg.tag = "g";
function gg() { return 2; }
ck("global-last-wins", g_before + "," + gg() + "," + gg.tag, "2,2,g");

// A SINGLE declaration must keep instantiating at its textual position, so
// its closure captures lexical bindings declared above it. Suppressing that
// emission (as a duplicate legitimately is) would leave `tag` unresolvable.
function c1() {
    const tag = "T";
    function K() { this.t = tag; }
    return new K().t;
}
ck("single-decl-captures-const", c1(), "T");

// Same, for a duplicate: the surviving body still captures correctly, since
// the hoist pass emits inside the scope that owns the lexical binding.
function c2() {
    const tag = "U";
    function K() { return tag + "1"; }
    function K() { return tag + "2"; }
    return K();
}
ck("dup-decl-captures-const", c2(), "U2");

// A declaration nested in a block is a DISTINCT binding and must not reuse
// the enclosing scope's register, or it would clobber it.
function b1() {
    function h() { return "outer"; }
    var seen = h();
    { function h() { return "inner"; } }
    return seen;
}
ck("block-decl-distinct", b1(), "outer");

// An escaped spelling denotes the same name, so `f` and `f` are one
// binding and the last body wins.
function e1() {
    function f() { return 1; }
    function f() { return 2; }
    return f();
}
ck("escaped-name-duplicate", e1(), 2);

// Duplicate declarations inside a BLOCK are lexical (§14.2.1), so unlike the
// function-top-level cases above they are a SyntaxError in strict mode rather
// than a last-one-wins rebinding. Checked via eval so the error is catchable.
var block_dup_threw = false;
try {
    eval("{ function q(){ return 1; } function q(){ return 2; } }");
} catch (e) {
    block_dup_threw = e instanceof SyntaxError;
}
ck("dup-in-block-is-error", block_dup_threw, true);

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error("FAIL"); }
