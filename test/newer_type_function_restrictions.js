// ES2024 §16.2 Forbidden Extensions + §27.1.4.2 + §10.4.2.
//
// Three regressions that only showed up once scripts defaulted to sloppy
// mode, since each one was previously masked by the reading code being
// strict or by an array carrying a materialised "length" property.
var passed = 0, failed = 0;
function eq(actual, expected, what) {
    if (actual === expected) { passed++; return; }
    failed++;
    print("FAIL: " + what + " -> got " + String(actual) + ", want " + String(expected));
}
function throws(fn, what) {
    try { fn(); } catch (e) {
        if (e instanceof TypeError) { passed++; return; }
        failed++; print("FAIL: " + what + " -> threw " + e.name + ", want TypeError");
        return;
    }
    failed++; print("FAIL: " + what + " -> did not throw");
}

// --- §16.2: caller/arguments are restricted on every newer-type function ---
// The reading code here is sloppy, so a verdict keyed on the reader's
// strictness would let all of these through.
async function asyncDecl() {}
function* genDecl() {}
async function* asyncGenDecl() {}
var container = {
    method() {}, *genMethod() {}, async asyncMethod() {},
    get getterMethod() {}, set setterMethod(x) {},
};
class K { m() {} static sm() {} }

var restricted = [
    ["async declaration", asyncDecl],
    ["async expression", async function () {}],
    ["generator declaration", genDecl],
    ["async generator", asyncGenDecl],
    ["arrow", () => {}],
    ["concise method", container.method],
    ["generator method", container.genMethod],
    ["async method", container.asyncMethod],
    ["getter", Object.getOwnPropertyDescriptor(container, "getterMethod").get],
    ["setter", Object.getOwnPropertyDescriptor(container, "setterMethod").set],
    ["class prototype method", K.prototype.m],
    ["class static method", K.sm],
    ["class constructor", K],
    ["bound function", function () {}.bind()],
    ["built-in (Function)", Function],
    ["built-in (bind)", Function.prototype.bind],
];
for (var i = 0; i < restricted.length; i++) {
    var name = restricted[i][0], f = restricted[i][1];
    throws(function () { return f.caller; }, name + " .caller");
    throws(function () { return f.arguments; }, name + " .arguments");
}

// Every access path reaches the same verdict: constant key, dynamic key,
// through a parameter, and Reflect.
throws(function () { return asyncDecl.arguments; }, "constant key");
throws(function () { var k = "arguments"; return asyncDecl[k]; }, "dynamic key");
throws((function (f) { return function () { return f.arguments; }; })(asyncDecl), "via parameter");
throws(function () { return Reflect.get(asyncDecl, "arguments"); }, "Reflect.get");

// A legacy sloppy function declaration or expression keeps Annex B.3.2's
// null, and a strict one still throws.
function legacyDecl() {}
var legacyExpr = function () {};
function strictDecl() { "use strict"; }
eq(legacyDecl.caller, null, "legacy declaration .caller is null");
eq(legacyDecl.arguments, null, "legacy declaration .arguments is null");
eq(legacyExpr.caller, null, "legacy expression .caller is null");
throws(function () { return strictDecl.caller; }, "strict declaration .caller");

// --- §10.4.2: an array's "length" is an own key, proxied or not ---
eq(Reflect.ownKeys([]).join(","), "length", "ownKeys of empty array");
eq(Reflect.ownKeys([1]).join(","), "0,length", "ownKeys of one-element array");
eq(Reflect.ownKeys(new Proxy([], {})).join(","), "length", "ownKeys of proxied array");
eq(Reflect.ownKeys(new Proxy([1], {})).join(","), "0,length", "ownKeys of proxied array with an element");
eq(Object.getOwnPropertyNames([]).join(","), "length", "getOwnPropertyNames of empty array");
// "length" is non-enumerable, so Object.keys still omits it.
eq(Object.keys([]).length, 0, "Object.keys of empty array is empty");
eq(Object.keys([1]).join(","), "0", "Object.keys of one-element array");

// Object.keys on a proxied array consults the descriptor for every key the
// ownKeys trap reported, "length" included.
var log = [];
Object.keys(new Proxy([], new Proxy({}, { get(t, pk) { log.push(pk); } })));
eq(log.join(","), "ownKeys,getOwnPropertyDescriptor", "proxied empty array trap order");
log = [];
Object.keys(new Proxy({}, new Proxy({}, { get(t, pk) { log.push(pk); } })));
eq(log.join(","), "ownKeys", "proxied plain object trap order");

// --- §27.1.4.2: next() forwards an absent value as no argument at all ---
var nextArgumentsLength = -1;
var syncIterator = {
    [Symbol.iterator]() { return this; },
    next() { nextArgumentsLength = arguments.length; return { done: true }; },
};
(async function () {
    for await (var _ of syncIterator);
    eq(nextArgumentsLength, 0, "absent value is not forwarded to inner next");

    // yield* resumes with a received value, so those calls do carry one.
    var yieldArgumentsLength = -1;
    var inner = {
        [Symbol.iterator]() { return this; },
        next(v) { yieldArgumentsLength = arguments.length; return { done: true }; },
    };
    function* outer() { yield* inner; }
    for (var __ of outer());
    eq(yieldArgumentsLength, 1, "yield* forwards its received value");

    print(failed === 0
        ? "PASS (" + passed + " assertions)"
        : "FAILED " + failed + " of " + (passed + failed));
})();
