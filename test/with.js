// Test: `with` statement (ES2024 §14.12), sloppy mode only.
//
// Scope resolution, assignment, nested shadowing, closures, deletion,
// @@unscopables, with-body lexical declarations, destructuring resolution
// order, and the strict-mode SyntaxError. Expectations are verified against
// node (`node test/with.js`), except the destructuring-order case, which
// asserts test262's order; node 24 resolves that binding after GetV.

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

// --- a `let` in a with body is block-scoped, never a property of the object ---
// Every read inside the body resolves dynamically, so the lexical binding has
// to be published to its own block environment rather than left in a register
// the env walk cannot reach.
var lexHolder = {};
var lexSeen;
with (lexHolder) { let inner = 7; lexSeen = inner; }
assert(lexSeen === 7, "let inside with is reachable through the env chain");
assert(!("inner" in lexHolder), "let inside with does not land on the with object");

// --- a `var` declared in a with body stays coherent with its env binding ---
// The object owns `shadow`, so the store goes to the object and the function's
// `shadow` keeps its previous value; when it does not, the store goes to the
// binding. Either way reads (inside and outside the body) must agree.
var shadow = 1;
var shadowOwner = { shadow: 9 };
with (shadowOwner) { var shadow = 5; }
assert(shadow === 1, "with-object-owned `var` does not overwrite the binding");
assert(shadowOwner.shadow === 5, "with-object-owned `var` writes the object");

var freed = 1;
var freeOwner = {};
with (freeOwner) { var freed = 6; }
assert(freed === 6, "unowned `var` in with writes the binding");
assert(freeOwner.freed === undefined, "unowned `var` in with leaves the object alone");

// --- a destructured `var` in a with body stores through ResolveBinding ---
// ES2024 §14.3.3.3: the Reference for the binding is created (running the with
// object's `has` trap) after the property name is evaluated and before GetV
// reads the source property. The expected order below is test262's
// (language/destructuring/binding/keyed-destructuring-property-reference-
// target-evaluation-order-with-bindings.js); node 24 defers the binding
// resolution past GetV, so this case is not node-comparable.
var orderLog = [];
var orderEnv = new Proxy({}, {
    has: function (t, k) { orderLog.push("binding::" + k); return false; }
});
var orderKey = { toString: function () { orderLog.push("sourceKey"); return "p"; } };
var orderSource = { get p() { orderLog.push("get source"); return undefined; } };
var orderDefault = 0;
(function () {
    var orderTarget;
    with (orderEnv) {
        var {[orderKey]: orderTarget = orderDefault} = orderSource;
    }
    assert(orderLog.join(",") === "binding::orderSource,binding::orderKey,sourceKey,"
        + "binding::orderTarget,get source,binding::orderDefault",
        "destructured var resolves its binding before reading the source; got " + orderLog.join(","));
    assert(orderTarget === 0, "destructured var in with applies its default");
})();

// --- strict code still rejects `with` at parse time ---
try {
    eval('(function () { "use strict"; with (scope) { } })');
    assert(false, "strict `with` should be a SyntaxError");
} catch (e) {
    assert(e instanceof SyntaxError, "strict `with` is a SyntaxError");
}

print("with tests: " + pass + " pass, " + fail + " fail");
if (fail > 0) { print("SOME TESTS FAILED"); }
