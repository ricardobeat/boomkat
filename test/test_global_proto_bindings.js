// The global environment is an object Environment Record whose binding object
// is the global object (ES2024 §9.1.1.4). HasBinding on such a record is
// HasProperty, not GetOwnProperty, so an INHERITED property of the global
// object -- everything on Object.prototype -- resolves as an unqualified name.
// `hasOwnProperty.call(o, k)` is the spelling minifiers emit for own-key tests.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

// Read: the bare name resolves to the inherited function.
ck("read-hasOwnProperty", typeof hasOwnProperty, "function");
ck("read-toString", typeof toString, "function");
ck("read-valueOf", typeof valueOf, "function");
ck("read-propertyIsEnumerable", typeof propertyIsEnumerable, "function");
ck("read-isPrototypeOf", typeof isPrototypeOf, "function");

// Call: the resolved value is callable and behaves as Object.prototype's.
ck("call-hasOwnProperty-true", hasOwnProperty.call({ a: 1 }, "a"), true);
ck("call-hasOwnProperty-false", hasOwnProperty.call({ a: 1 }, "b"), false);
ck("call-hasOwnProperty-inherited", hasOwnProperty.call(Object.create({ z: 1 }), "z"), false);
ck("call-isPrototypeOf", isPrototypeOf.call(Object.prototype, {}), true);

// It is the same function object reached via the global object.
ck("identity-globalThis", hasOwnProperty === globalThis.hasOwnProperty, true);
ck("identity-Object-proto", hasOwnProperty === Object.prototype.hasOwnProperty, true);

// typeof on an inherited global binding is the value's type, not "undefined".
// (typeof on a genuinely unresolvable name stays "undefined" and must not throw.)
ck("typeof-inherited", typeof hasOwnProperty, "function");
ck("typeof-unresolvable", typeof totally_not_a_global_xyz, "undefined");

// A genuinely unbound name still throws ReferenceError on read.
var threw = false;
try { totally_not_a_global_xyz.foo; } catch (e) { threw = e instanceof ReferenceError; }
ck("unbound-read-throws", threw, true);

// A local binding shadows the inherited global one.
function shadowed() {
    var hasOwnProperty = 42;
    return hasOwnProperty;
}
ck("local-shadows", shadowed(), 42);

// A parameter shadows it too.
function shadowedParam(hasOwnProperty) { return hasOwnProperty; }
ck("param-shadows", shadowedParam("p"), "p");

// An own global property takes precedence over the inherited one.
globalThis.valueOf = "own";
ck("own-global-wins", valueOf, "own");
delete globalThis.valueOf;
ck("own-deleted-falls-back", typeof valueOf, "function");

// Resolution works from inside a nested function scope, where the env walk
// runs through several links before reaching the global record.
function outerScope() {
    function innerScope() {
        return hasOwnProperty.call({ k: 1 }, "k");
    }
    return innerScope();
}
ck("nested-scope-call", outerScope(), true);

// Repeated resolution is stable (the inline caches must not poison the miss).
var stable = true;
for (var i = 0; i < 50; i++) {
    if (hasOwnProperty.call({ n: i }, "n") !== true) { stable = false; break; }
}
ck("repeated-resolution", stable, true);

// An inherited ACCESSOR is a binding too, and GetBindingValue does the
// ordinary [[Get]] on the binding object, so the getter's receiver is the
// global object -- not the prototype that owns the accessor.
Object.defineProperty(Object.prototype, "inheritedGetter", {
    get: function () { return this === globalThis ? "recv-is-global" : "recv-is-other"; },
    configurable: true
});
ck("inherited-accessor-read", inheritedGetter, "recv-is-global");
ck("inherited-accessor-typeof", typeof inheritedGetter, "string");
delete Object.prototype.inheritedGetter;

// A set-only accessor reads as undefined, exactly as a property access would.
Object.defineProperty(Object.prototype, "setOnly", {
    set: function (v) { },
    configurable: true
});
ck("set-only-accessor", typeof setOnly, "undefined");
delete Object.prototype.setOnly;

// An own global property still shadows an inherited accessor. Defined rather
// than assigned: a plain assignment would run the inherited SETTER (or throw
// when there is none), which is a different rule.
Object.defineProperty(Object.prototype, "shadowMe", {
    get: function () { return "inherited"; },
    configurable: true
});
Object.defineProperty(globalThis, "shadowMe", {
    value: "own", configurable: true, writable: true
});
ck("own-shadows-accessor", shadowMe, "own");
delete globalThis.shadowMe;
delete Object.prototype.shadowMe;

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error("FAIL"); }
