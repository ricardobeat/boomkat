// The engine is strict-only: a SINGLE execution mode with no runtime
// strictness flag (AGENTS.md "Strict-Only Mode").  Bodies compiled by the
// dynamic Function / GeneratorFunction / AsyncFunction constructors used to be
// the one hole in that design — they were compiled sloppy, so implicit globals
// silently worked inside them.
//
// What survives is `this`-substitution, which is a SEPARATE rule from
// strictness here: FuncFlags.subst_global_this is set only on dynamic bodies so
// the ubiquitous UMD idiom `Function('return this')()` keeps yielding the
// global object.  A "use strict" directive in the dynamic body clears it.
//
// Expectations verified against node v24 (where both behaviours follow from
// the body being sloppy; here only the `this` half is retained).

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

function throwsRef(fn) {
    try { fn(); return false; } catch (e) { return e instanceof ReferenceError; }
}
function throwsSyntax(fn) {
    try { fn(); return false; } catch (e) { return e instanceof SyntaxError; }
}

var GeneratorFunction = Object.getPrototypeOf(function* () {}).constructor;
var AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// --- implicit globals are rejected inside dynamic bodies -------------------
// Previously returned "number": the assignment created a global.
assert(throwsRef(new Function("implicit_zz = 1; return typeof implicit_zz")),
    "implicit global in Function body throws ReferenceError");
assert(typeof implicit_zz === "undefined",
    "failed implicit global did not leak onto the global object");

assert(throwsRef(function () {
    return new GeneratorFunction("implicit_yy = 1; yield 1")().next();
}), "implicit global in GeneratorFunction body throws ReferenceError");

// A function nested inside a dynamic body is also strict.
assert(throwsRef(new Function(
    "function inner() { implicit_ww = 3; } return inner()")),
    "implicit global in a function nested in a Function body throws");

// Assignment to a declared binding still works — the fix must not reject
// ordinary stores.
assert(new Function("var ok = 7; return ok")() === 7,
    "declared var inside a dynamic body still assignable");
assert(new Function("a", "a = a + 1; return a")(1) === 2,
    "parameter inside a dynamic body still assignable");

// --- unqualified delete is a SyntaxError, including for register locals ----
// `delete <local>` used to return true: a name resolved to a register missed
// the IdentifierReference check and fell through to the "not a Reference"
// branch, which unconditionally emits true.
assert(throwsSyntax(function () { return new Function("var q = 1; return delete q"); }),
    "delete of a local var in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function("a", "return delete a"); }),
    "delete of a parameter in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function("return delete undeclared_qq"); }),
    "delete of an undeclared name in a dynamic body is a SyntaxError");

// Property deletion is unaffected.
var delObj = { a: 1, b: 2 };
assert(delete delObj.a === true && !("a" in delObj), "delete obj.prop still works");
var delKey = "b";
assert(delete delObj[delKey] === true && !("b" in delObj), "delete obj[key] still works");
assert(delete 5 === true, "delete of a non-reference still returns true");

// --- other sloppy-mode syntax stays rejected ------------------------------
assert(throwsSyntax(function () { return new Function("with ({}) { return 1; }"); }),
    "`with` in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function("return 010"); }),
    "legacy octal literal in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function("return '\\101'"); }),
    "legacy octal escape in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function("a", "a", "return a"); }),
    "duplicate parameters in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new GeneratorFunction("a", "a", "yield a"); }),
    "duplicate parameters in a GeneratorFunction body is a SyntaxError");

// --- this-substitution MUST keep working (UMD idiom) ----------------------
assert(new Function("return this")() === globalThis,
    "Function('return this')() yields the global object");
assert(new Function("return this").call(undefined) === globalThis,
    "explicit undefined receiver coerces to the global object");
assert(new Function("return this").call(null) === globalThis,
    "explicit null receiver coerces to the global object");

// A real receiver is never replaced.
var recv = {};
assert(new Function("return this").call(recv) === recv,
    "object receiver passed through unchanged");
assert(typeof new Function("return this").call(5) === "number",
    "primitive receiver passed through without boxing to global");

// A "use strict" directive in the dynamic body opts back out of substitution,
// matching an ordinary strict function.
assert(new Function("'use strict'; return this")() === undefined,
    "'use strict' dynamic body keeps an undefined receiver");

// Ordinary (non-dynamic) functions never substitute — they are already strict.
assert((function () { return this; }).call(undefined) === undefined,
    "ordinary function receiver stays undefined");

// A function nested inside a dynamic body is an ordinary strict function: it
// does NOT inherit subst_global_this.
assert(new Function("return (function () { return this; }).call(undefined)")() === undefined,
    "function nested in a dynamic body does not substitute this");

// AsyncFunction bodies compile and run.
var asyncRan = 0;
new AsyncFunction("return 42")().then(function (v) {
    asyncRan = 1;
    assert(v === 42, "AsyncFunction body returns its value");
    report();
}, function (e) {
    asyncRan = 1;
    fail++;
    print("FAIL: AsyncFunction body rejected: " + e);
    report();
});

function report() {
    if (!asyncRan) { fail++; print("FAIL: async continuation never ran"); }
    print("strict_only_dynamic_function: " + pass + " passed, " + fail + " failed");
    if (fail > 0) { print("SOME TESTS FAILED"); throw new Error("FAIL"); }
}
