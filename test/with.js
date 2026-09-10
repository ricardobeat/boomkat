// Test: `with` statement (ES2024 §14.12), sloppy mode only.
//
// Scope resolution, assignment, nested shadowing, closures, deletion,
// @@unscopables, and the strict-mode SyntaxError. Expectations verified
// against node (`node test/with.js`).

if (typeof print === "undefined") { var print = function (s) { console.log(s); }; }

var pass = 0, fail = 0;
function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

// --- basic read / write through the with object ---
var scope = { x: 10, y: 20 };
with (scope) {
    assert(x + y === 30, "with reads object properties");
    x = 99;
    assert(scope.x === 99, "with assignment lands on the object");
}

// A read of a name that is only on the with object must not create a global.
var onlyOnObj = { solo: 1 };
var soloLeaked = true;
try { with (onlyOnObj) { if (solo === 1) { soloLeaked = true; } } } catch (e) { soloLeaked = (e instanceof ReferenceError); }
assert(soloLeaked === true, "name not on the with object resolves outward or throws");
with (onlyOnObj) { solo = 2; }
assert(onlyOnObj.solo === 2 && typeof globalThis.solo === "undefined",
    "with assignment targets the object, not a global");

// --- nested with: inner shadows outer ---
var ns = { a: "outer" };
var innerA, outerA;
with (ns) {
    with ({ a: "inner" }) { innerA = a; }
    outerA = a;
}
assert(innerA === "inner" && outerA === "outer", "nested with shadowing");

// --- with inside a function ---
function f() { with ({ q: 3 }) { return q; } }
assert(f() === 3, "with inside a function");

// --- var inside with binds in the function scope, not the with object ---
var vo = { v: 10 };
var w;
with (vo) { w = v + 1; }
assert(w === 11, "var inside with keeps normal binding rules");

// --- closures capture with-env resolution ---
var co = { c: 99 };
var getc;
with (co) { getc = function () { return c; }; }
assert(getc() === 99, "closure created in with reads the with object");
co.c = 100;
assert(getc() === 100, "with-env closure sees live object values");

// --- delete through with removes the object's property ---
var dpo = { d: 1 };
with (dpo) { delete d; }
assert(!("d" in dpo), "delete inside with removes the property");

// --- prototype chain lookup ---
var proto = { inherited: "yes" };
var child = Object.create(proto);
child.own = "own";
var combo;
with (child) { combo = own + " " + inherited; }
assert(combo === "own yes", "with walks the prototype chain");

// --- @@unscopables hides a binding from resolution ---
var sc = { alpha: 1, beta: 2 };
sc[Symbol.unscopables] = { beta: true };
var uAlpha, uBetaType;
with (sc) {
    uAlpha = alpha;
    uBetaType = typeof beta;
}
assert(uAlpha === 1, "unscopables leaves other keys visible");
assert(uBetaType === "undefined", "@@unscopables hides the key from with");

// --- strict code still rejects `with` at parse time ---
try {
    eval('(function () { "use strict"; with (scope) { } })');
    assert(false, "strict `with` should be a SyntaxError");
} catch (e) {
    assert(e instanceof SyntaxError, "strict `with` is a SyntaxError");
}

print("with tests: " + pass + " pass, " + fail + " fail");
if (fail > 0) { print("SOME TESTS FAILED"); }
