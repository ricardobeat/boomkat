// Block-scoped FunctionDeclarations are instantiated at block entry, not
// left in the temporal dead zone.
//
// Found loading papaparse, which threw "Cannot access 't' before
// initialization" from Papa.parse(): a `{ ... }` block pre-scan collected its
// top-level `let`/`const`/`class` AND `function` names into one list and
// emitted INITTZ for every one of them at block entry. ES2024 §14.2.11
// BlockDeclarationInstantiation treats the two kinds differently:
//
//   * step 3(d)/(f): a let/const/class binding is created UNINITIALIZED, so
//     reading it before its declaration is a ReferenceError (the TDZ);
//   * step 3(a)(ii): a FunctionDeclaration runs InstantiateFunctionObject
//     right there, so its binding already holds the closure before the
//     block's first statement runs.
//
// Poisoning a function name with the TDZ sentinel instead made any read
// before the declaration's own textual position throw -- including the
// mutually-recursive block-scoped helpers papaparse calls. §14.12.4
// CaseBlockEvaluation runs the same instantiation over a whole switch
// CaseBlock, so a clause could not call a function declared in a later one.
//
// The engine is strict-only, so Annex B §B.3.2.1 (two plain
// FunctionDeclarations sharing a name in one block, and hoisting the binding
// out to the enclosing var scope) does NOT apply: a duplicate is a
// SyntaxError and the binding stays confined to the block. Every expectation
// below was cross-checked against qjs running the same source with a
// "use strict" prologue.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " -- expected " + expected + " got " + actual);
        failures++;
    }
}

// --- the core bug: called before its own textual position ---
{
    check("typeofBeforeDecl", typeof f, "function");
    check("callBeforeDecl", f(), 1);
    function f() { return 1; }
    check("callAfterDecl", f(), 1);
}

// --- let/const/class keep their TDZ: the fix must not exempt them ---
{
    function coexist() { return "fn"; }
    var threw = "none";
    try { void tdzLet; } catch (e) { threw = e.name; }
    check("letStillTdz", threw, "ReferenceError");
    let tdzLet = 1;
    check("letAfterInit", tdzLet, 1);
}
{
    var threwConst = "none";
    try { void tdzConst; } catch (e) { threwConst = e.name; }
    check("constStillTdz", threwConst, "ReferenceError");
    const tdzConst = 2;
    check("constAfterInit", tdzConst, 2);
}
{
    var threwClass = "none";
    try { void TdzClass; } catch (e) { threwClass = e.name; }
    check("classStillTdz", threwClass, "ReferenceError");
    class TdzClass {}
    check("classAfterInit", typeof TdzClass, "function");
}

// --- mutual recursion across textual order (the papaparse shape) ---
{
    check("mutualEven", even(4), true);
    check("mutualOdd", odd(3), true);
    function even(n) { return n === 0 ? true : odd(n - 1); }
    function odd(n) { return n === 0 ? false : even(n - 1); }
}

// --- the closure captures the block's OWN lexical bindings ---
{
    const captured = 42;
    check("capturesBlockConst", K(), 42);
    function K() { return captured; }
}

// --- instantiated ONCE: a property stored before the declaration survives ---
// A second function object built at the textual position would discard it.
{
    tagged.stamp = "kept";
    function tagged() {}
    check("singleInstantiation", tagged.stamp, "kept");
}

// --- the binding shadows an outer one for the WHOLE block, and only there ---
function shadowed() { return "outer"; }
{
    check("shadowBeforeDecl", shadowed(), "inner");
    function shadowed() { return "inner"; }
    check("shadowAfterDecl", shadowed(), "inner");
}
check("shadowOutsideBlock", shadowed(), "outer");

// --- strict mode confines the binding to the block (no Annex B hoisting) ---
{
    function confined() { return 1; }
}
check("noLeakOutOfBlock", typeof confined, "undefined");

// --- nested blocks each instantiate their own ---
{
    function nest() { return "a"; }
    {
        function nest() { return "b"; }
        check("innerNestWins", nest(), "b");
    }
    check("outerNestRestored", nest(), "a");
}

// --- generators and async functions take the same path ---
{
    check("generatorBeforeDecl", G().next().value, "gen");
    function* G() { yield "gen"; }
}
{
    check("asyncTypeofBeforeDecl", typeof A, "function");
    async function A() { return "async"; }
}

// --- a switch CaseBlock instantiates over the whole block (§14.12.4) ---
switch (1) {
    case 1:
        check("switchCallsLaterClauseFn", laterClause(), "later");
        break;
    case 2:
        function laterClause() { return "later"; }
}
// ...and a let in a CaseBlock still gets its TDZ.
switch (1) {
    case 1: {
        var threwSwitch = "none";
        try { void switchLet; } catch (e) { threwSwitch = e.name; }
        check("switchLetStillTdz", threwSwitch, "ReferenceError");
        break;
    }
    case 2:
        let switchLet = 1;
}

// --- block inside a function body: captures a parameter, called early ---
function wrapper(param) {
    {
        return cap();
        function cap() { return param; }
    }
}
check("blockInFunctionBody", wrapper("p"), "p");

// --- block inside an arrow body (arrows do not go through block()) ---
var arrowed = () => {
    {
        return inner();
        function inner() { return "arrow"; }
    }
};
check("blockInArrowBody", arrowed(), "arrow");

// --- catch and try blocks ---
try {
    check("tryBlockFn", inTry(), "try");
    function inTry() { return "try"; }
} catch (e) {
    failures++;
}
try {
    throw 1;
} catch (err) {
    check("catchBlockFn", inCatch(), "catch");
    function inCatch() { return "catch"; }
}

// --- a fresh binding per loop iteration ---
{
    var seen = [];
    for (let i = 0; i < 3; i++) {
        seen.push(perIter());
        function perIter() { return i; }
    }
    check("perIterationBinding", seen.join(","), "0,1,2");
}

// --- Function.prototype.toString source retention is unaffected ---
{
    check("toStringRetained",
          src.toString().replace(/\s+/g, " "),
          "function src(a, b) { return a + b; }");
    function src(a, b) { return a + b; }
}

if (failures === 0) {
    print("PASS: block-scoped function declarations instantiate at block entry");
} else {
    print("FAILED: " + failures + " check(s)");
    throw new Error(failures + " block-scoped function declaration check(s) failed");
}
