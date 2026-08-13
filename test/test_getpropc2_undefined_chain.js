// A two-link dotted chain `o.a.b` compiles to the fused GETPROPC2 opcode.
// §7.3.2 GetV runs RequireObjectCoercible first, so when the intermediate is
// null or undefined the second hop must throw a TypeError -- exactly as the
// unfused GETPROPC pair does. The fused path used to answer `undefined`
// instead, turning a broken chain into a silently wrong value.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }
function msgOf(fn) {
    try { fn(); return "NO THROW"; } catch (e) { return e instanceof TypeError ? e.message : "wrong type: " + e; }
}

var o = {};
var withNull = { a: null };

// The fused two-hop shape: this is the one that silently returned undefined.
ck("two-link-undefined", msgOf(function () { return o.a.b; }),
   "Cannot read properties of undefined (reading 'b')");
ck("two-link-null", msgOf(function () { return withNull.a.b; }),
   "Cannot read properties of null (reading 'b')");

// Parenthesised, so still a two-hop chain.
ck("parenthesised", msgOf(function () { return (o.a).b; }),
   "Cannot read properties of undefined (reading 'b')");

// Longer chains throw at the FIRST broken link, naming that link's key.
ck("three-link", msgOf(function () { return o.a.b.c; }),
   "Cannot read properties of undefined (reading 'b')");

// Unfused spellings of the same access, which already threw, must not change.
ck("via-local", msgOf(function () { var x = o.a; return x.b; }),
   "Cannot read properties of undefined (reading 'b')");
ck("computed", msgOf(function () { return o.a["b"]; }),
   "Cannot read properties of undefined (reading 'b')");
ck("literal-undefined", msgOf(function () { return undefined.b; }),
   "Cannot read properties of undefined (reading 'b')");

// A call through a broken chain throws on the property read, before the call.
ck("call-through-chain", msgOf(function () { return o.a.b(); }),
   "Cannot read properties of undefined (reading 'b')");

// Working chains keep working: the throw must be limited to null/undefined
// intermediates, not any non-object one.
var deep = { a: { b: "leaf" } };
ck("working-chain", deep.a.b, "leaf");
ck("chain-missing-leaf", deep.a.zzz, undefined);

// Primitive intermediates auto-box rather than throw.
ck("string-intermediate", ({ s: "hi" }).s.length, 2);
ck("number-intermediate", ({ n: 5 }).n.toFixed(1), "5.0");
ck("boolean-intermediate", ({ b: true }).b.toString(), "true");
ck("array-length-hop", ({ arr: [1, 2, 3] }).arr.length, 3);

// The intermediate is still available to a following call as `this`, which is
// what the temp register the fused pair writes back is for.
var recv = { m: { z: function () { return this === recv.m; } } };
ck("temp-register-this", recv.m.z(), true);

// Accessors on either hop still run.
var acc = { get a() { return { b: "fromGetter" }; } };
ck("getter-hop1", acc.a.b, "fromGetter");
var acc2 = { a: { get b() { return "leafGetter"; } } };
ck("getter-hop2", acc2.a.b, "leafGetter");

// A getter returning undefined makes the second hop throw, same as a plain
// undefined intermediate.
var accUndef = { get a() { return undefined; } };
ck("getter-returns-undefined", msgOf(function () { return accUndef.a.b; }),
   "Cannot read properties of undefined (reading 'b')");

// Repeated execution is stable: the inline caches on both hops must not turn
// a throwing chain into a passing one (or vice versa).
var stable = true;
for (var i = 0; i < 50; i++) {
    if (deep.a.b !== "leaf") { stable = false; break; }
    if (msgOf(function () { return o.a.b; }) !== "Cannot read properties of undefined (reading 'b')") { stable = false; break; }
}
ck("repeated-stable", stable, true);

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error("FAIL"); }
