// Dynamic Function / GeneratorFunction / AsyncFunction bodies are sloppy by
// default (ES2024 §20.2.1.1): implicit globals create global properties,
// Annex B `delete <name>` and duplicate parameters parse, and octal
// literals/escapes decode. A "use strict" directive in the body opts back
// into strict semantics, where implicit globals and `delete <name>` throw.

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

// --- implicit globals work inside sloppy dynamic bodies --------------------
assert(new Function("implicit_zz = 1; return typeof implicit_zz")() === "number",
    "implicit global in a Function body creates the global");
assert(typeof implicit_zz === "number",
    "implicit global leaked onto the global object as sloppy semantics dictate");

assert(new GeneratorFunction("implicit_yy = 1; yield 1")().next().value === 1,
    "implicit global in a GeneratorFunction body works");

assert(new Function("function inner() { implicit_ww = 3; } inner(); return implicit_ww")() === 3,
    "implicit global in a function nested in a Function body works");

// A strict body still rejects the assignment.
assert(throwsRef(new Function('"use strict"; implicit_sv = 1; return typeof implicit_sv')),
    "implicit global in a strict Function body throws ReferenceError");
assert(typeof implicit_sv === "undefined",
    "failed strict implicit global did not leak onto the global object");

// Assignment to a declared binding still works — the fix must not reject
// ordinary stores.
assert(new Function("var ok = 7; return ok")() === 7,
    "declared var inside a dynamic body still assignable");
assert(new Function("a", "a = a + 1; return a")(1) === 2,
    "parameter inside a dynamic body still assignable");

// --- Annex B.3.2 `delete <name>` in sloppy dynamic bodies ------------------
// A present var/parameter binding reports false; an unresolvable name
// reports true.
assert(new Function("var q = 1; return delete q")() === false,
    "sloppy delete of a local var returns false");
assert(new Function("a", "return delete a")() === false,
    "sloppy delete of a parameter returns false");
assert(new Function("return delete undeclared_qq")() === true,
    "sloppy delete of an undeclared name returns true");

// The strict forms all throw SyntaxError.
assert(throwsSyntax(function () { return new Function('"use strict"; var q = 1; return delete q'); }),
    "strict delete of a local var in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function('"use strict"; a', "return delete a"); }),
    "strict delete of a parameter in a dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function('"use strict"; return delete undeclared_qq'); }),
    "strict delete of an undeclared name in a dynamic body is a SyntaxError");

// Property deletion is unaffected.
var delObj = { a: 1, b: 2 };
assert(delete delObj.a === true && !("a" in delObj), "delete obj.prop still works");
var delKey = "b";
assert(delete delObj[delKey] === true && !("b" in delObj), "delete obj[key] still works");
assert(delete 5 === true, "delete of a non-reference still returns true");

// --- sloppy dynamic bodies accept Annex B syntax ---------------------------
// `with` works end-to-end in sloppy dynamic bodies.
assert(new Function("with ({ x: 7 }) { return x; }")() === 7,
    "`with` in a dynamic body resolves against the object");

assert(new Function("return 010")() === 8,
    "legacy octal literal decodes to its base-8 value");
assert(new Function("return '\\101'")() === "A",
    "legacy octal escape decodes to its character");
assert(new Function("a", "a", "return a")(1, 2) === 2,
    "duplicate parameters in a dynamic body take the last binding");
assert(new GeneratorFunction("a", "a", "yield a")(1, 2).next().value === 2,
    "duplicate parameters in a GeneratorFunction body take the last binding");

// The strict forms still reject.
assert(throwsSyntax(function () { return new Function('"use strict"; with ({}) { return 1; }'); }),
    "`with` in a strict dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function('"use strict"; return 010'); }),
    "legacy octal literal in a strict dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function('"use strict"; return \'\\101\''); }),
    "legacy octal escape in a strict dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new Function('"use strict";', "a", "a", "return a"); }),
    "duplicate parameters in a strict dynamic body is a SyntaxError");
assert(throwsSyntax(function () { return new GeneratorFunction('"use strict";', "a", "a", "yield a"); }),
    "duplicate parameters in a strict GeneratorFunction body is a SyntaxError");

// --- this-substitution keeps working (UMD idiom) ---------------------------
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
assert(typeof new Function("return this").call(5) === "object",
    "sloppy ToObject-wraps a primitive receiver (ES2024 §10.4.1.2)");

// A "use strict" directive in the dynamic body opts out of substitution.
assert(new Function("'use strict'; return this")() === undefined,
    "'use strict' dynamic body keeps an undefined receiver");

// A function nested inside a sloppy dynamic body inherits its sloppiness:
// an ordinary sloppy function substitutes too.
assert(new Function("return (function () { return this; }).call(undefined)")() === globalThis,
    "function nested in a dynamic body substitutes like its sloppy parent");
assert(new Function("'use strict'; return (function () { return this; }).call(undefined)")() === undefined,
    "function nested in a strict dynamic body stays strict");

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
