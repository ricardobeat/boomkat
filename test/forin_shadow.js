// for-in shadowing: a NON-ENUMERABLE own key must suppress a same-named
// enumerable key further up the prototype chain.
//
// ES EnumerateObjectProperties records every own key it visits — including
// non-enumerable ones — in the "already visited" set, so the enumerable
// namesake on a prototype is never yielded.  The engine previously only
// recorded *enumerable* own keys, so such a pair yielded the proto key.
//
// Kept separate from test/forin.js, which is a basic smoke test for
// enumeration itself; this file is specifically about the shadowing /
// visited-set rule and its interaction with the integer-index and string
// enumeration phases.  Expectations verified against node v24.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

function keysOf(o) {
    var out = [];
    for (var k in o) { out.push(k); }
    return out;
}
function assertKeys(o, expected, msg) {
    var got = keysOf(o).join(",");
    if (got === expected) { pass++; }
    else { fail++; print("FAIL: " + msg + " -- expected [" + expected + "] got [" + got + "]"); }
}

// --- 1. Non-enumerable own string key shadows an enumerable proto key ---
var proto1 = { a: "proto-a", b: "proto-b" };
var obj1 = Object.create(proto1);
Object.defineProperty(obj1, "a", { value: "own-a", enumerable: false });
assertKeys(obj1, "b", "non-enumerable own 'a' shadows enumerable proto 'a'");

// The property is still there and readable — it is only hidden from for-in.
assert(obj1.a === "own-a", "shadowed own value still readable");
assert(Object.getOwnPropertyNames(obj1).indexOf("a") !== -1, "shadowed own key still an own name");

// --- 2. Non-enumerable own integer-index key shadows an enumerable proto index ---
// Integer indices and strings go through separate enumeration phases, so both
// need covering.
var proto2 = { 0: "p0", 1: "p1", 2: "p2" };
var obj2 = Object.create(proto2);
Object.defineProperty(obj2, "1", { value: "own1", enumerable: false });
assertKeys(obj2, "0,2", "non-enumerable own index 1 shadows enumerable proto index 1");

// --- 3. Mixed index + string shadowing in one object ---
var proto3 = { 0: "p0", 5: "p5", x: "px", y: "py" };
var obj3 = Object.create(proto3);
Object.defineProperty(obj3, "5", { value: 1, enumerable: false });
Object.defineProperty(obj3, "x", { value: 2, enumerable: false });
assertKeys(obj3, "0,y", "mixed index+string non-enumerable shadowing");

// --- 4. Mid-chain non-enumerable key shadows one further up (3+ levels) ---
// The visited-set rule applies at every level, not just the direct object:
// level 1 (top proto) has enumerable 'm'; level 2 (mid) has NON-enumerable 'm',
// which must suppress it; the leaf has neither.
var top4 = { m: "top-m", keep: "top-keep" };
var mid4 = Object.create(top4);
Object.defineProperty(mid4, "m", { value: "mid-m", enumerable: false });
var leaf4 = Object.create(mid4);
leaf4.own = 1;
assertKeys(leaf4, "own,keep", "mid-chain non-enumerable 'm' shadows top-level enumerable 'm'");

// Same with an integer index mid-chain.
var top4b = { 3: "top3", 9: "top9" };
var mid4b = Object.create(top4b);
Object.defineProperty(mid4b, "3", { value: 0, enumerable: false });
var leaf4b = Object.create(mid4b);
assertKeys(leaf4b, "9", "mid-chain non-enumerable index shadows top-level enumerable index");

// --- 5. Four-level chain, each level hiding the next ---
var l1 = { a: 1, b: 2, c: 3, d: 4 };
var l2 = Object.create(l1);
Object.defineProperty(l2, "a", { value: 0, enumerable: false });
var l3 = Object.create(l2);
Object.defineProperty(l3, "b", { value: 0, enumerable: false });
var l4 = Object.create(l3);
Object.defineProperty(l4, "c", { value: 0, enumerable: false });
assertKeys(l4, "d", "4-level chain: each non-enumerable level hides its namesake");

// --- 6. An ENUMERABLE own key still shadows (and is itself yielded once) ---
var proto6 = { a: "pa", b: "pb" };
var obj6 = Object.create(proto6);
obj6.a = "oa";
assertKeys(obj6, "a,b", "enumerable own key yielded once, shadows proto namesake");

// --- 7. Non-enumerable key on the PROTO does not hide anything of its own,
//        and does not stop a lower enumerable own key from being yielded ---
var proto7 = {};
Object.defineProperty(proto7, "hidden", { value: 1, enumerable: false });
proto7.shown = 2;
var obj7 = Object.create(proto7);
// defineProperty, not assignment: the proto's `hidden` is non-writable, so a
// plain `obj7.hidden = 3` would be rejected rather than creating an own key.
Object.defineProperty(obj7, "hidden", { value: 3, enumerable: true });
assertKeys(obj7, "hidden,shown", "enumerable own key yielded even when proto namesake non-enumerable");

// --- 8. Symbol keys must not participate in for-in ---
// NOTE: only non-enumerable symbol keys are asserted here. *Enumerable* symbol
// keys are currently yielded by collect_forin_keys ("Phase 3"), which is a
// separate pre-existing spec violation unrelated to the shadowing fix — see the
// engine's vm_forin.c3 Phase 3 loop. Asserting it here would leave a
// permanently-red test that masks real regressions in this file.
var sym = Symbol("s");
var protoS = { str: "proto-str" };
var objS = Object.create(protoS);
Object.defineProperty(objS, sym, { value: "own-sym-ne", enumerable: false });
assertKeys(objS, "str", "non-enumerable symbols not enumerated by for-in");

// A non-enumerable symbol own key must not suppress a same-*named* string key
// (a Symbol("s") and the string "s" are distinct keys, so nothing is shadowed).
var protoS2 = { s: "string-key" };
var objS2 = Object.create(protoS2);
Object.defineProperty(objS2, Symbol("s"), { value: 1, enumerable: false });
assertKeys(objS2, "s", "non-enumerable symbol does not shadow a same-named string key");

// A non-enumerable symbol on the *prototype* is likewise invisible.
var protoS3 = { keep: 1 };
Object.defineProperty(protoS3, Symbol("hidden"), { value: 1, enumerable: false });
assertKeys(Object.create(protoS3), "keep", "non-enumerable proto symbol not enumerated");

// --- 9. Enumeration ORDER: integer indices ascending, then strings in
//        insertion order — including across the prototype chain ---
var protoO = {};
protoO.pz = 1;
protoO[100] = 1;
protoO.pa = 1;
protoO[2] = 1;
var objO = Object.create(protoO);
objO.zz = 1;
objO[10] = 1;
objO.aa = 1;
objO[1] = 1;
// Own level first: indices 1,10 ascending then strings zz,aa in insertion
// order; then the proto level: indices 2,100 ascending then strings pz,pa.
assertKeys(objO, "1,10,zz,aa,2,100,pz,pa",
    "order: per level, integer indices ascending then strings in insertion order");

// Order is preserved when a non-enumerable own key removes a proto entry.
var protoO2 = { 1: 1, 2: 2, 3: 3, a: 1, b: 2, c: 3 };
var objO2 = Object.create(protoO2);
Object.defineProperty(objO2, "2", { value: 0, enumerable: false });
Object.defineProperty(objO2, "b", { value: 0, enumerable: false });
objO2[0] = 1;
objO2.z = 1;
assertKeys(objO2, "0,z,1,3,a,c", "order preserved with shadowed entries removed");

// --- 10. Arrays: a non-enumerable own index shadows an enumerable proto index.
//         (Array index storage may differ from plain-object property storage.)
var arrProto = { 0: "ap0", 1: "ap1", 2: "ap2", extra: "ae" };
var arr = [];
Object.setPrototypeOf(arr, arrProto);
Object.defineProperty(arr, "1", { value: "own1", enumerable: false, configurable: true });
assertKeys(arr, "0,2,extra", "array: non-enumerable own index shadows proto index");

// A real array element still enumerates normally and shadows its proto namesake.
var arr2 = [10, 20];
Object.setPrototypeOf(arr2, { 0: "x", 1: "y", 2: "z" });
assertKeys(arr2, "0,1,2", "array: real elements shadow proto indices, proto extras still yielded");

// 'length' is a non-enumerable own key of every array — it must never appear,
// and it must suppress an enumerable proto 'length'.
var arr3 = [1];
Object.setPrototypeOf(arr3, { length: "proto-length", other: 1 });
assertKeys(arr3, "0,other", "array 'length' (non-enumerable own) shadows enumerable proto 'length'");

// --- 11. Object.defineProperty toggling enumerability changes visibility ---
var protoT = { t: "proto-t" };
var objT = Object.create(protoT);
Object.defineProperty(objT, "t", { value: 1, enumerable: true, configurable: true });
assertKeys(objT, "t", "enumerable own 't' yielded");
Object.defineProperty(objT, "t", { enumerable: false });
assertKeys(objT, "", "redefined non-enumerable 't' hides both own and proto");

// --- 12. Class prototypes: class methods are non-enumerable ---
class CBase { foo() { return 1; } }
class CDerived extends CBase { foo() { return 2; } bar() { return 3; } }
var ci = new CDerived();
ci.data = 1;
// All class methods are non-enumerable, so only the own data property shows.
assertKeys(ci, "data", "class methods are non-enumerable and never enumerated");

// An enumerable property added to a base class prototype IS enumerated...
CBase.prototype.visible = 1;
assertKeys(ci, "data,visible", "enumerable proto property on a base class is enumerated");
// ...unless a non-enumerable namesake sits between it and the object.
Object.defineProperty(CDerived.prototype, "visible", { value: 2, enumerable: false });
assertKeys(ci, "data", "non-enumerable derived-class-proto key shadows base-class enumerable key");

// --- 13. Getters: an accessor is a normal property for shadowing purposes ---
var protoG = { g: "proto-g" };
var objG = Object.create(protoG);
Object.defineProperty(objG, "g", { get: function () { return "own-g"; }, enumerable: false });
assertKeys(objG, "", "non-enumerable own accessor shadows enumerable proto data key");
assert(objG.g === "own-g", "shadowing accessor still callable");

// --- 14. Object.create with a property descriptor map ---
var objD = Object.create({ a: 1, b: 2 }, {
    a: { value: 9, enumerable: false },
    c: { value: 8, enumerable: true }
});
assertKeys(objD, "c,b", "Object.create descriptor map: non-enumerable 'a' shadows proto 'a'");

// --- 15. Null-prototype object with a non-enumerable key ---
var objN = Object.create(null);
Object.defineProperty(objN, "hidden", { value: 1, enumerable: false });
objN.shown = 2;
assertKeys(objN, "shown", "null-prototype: non-enumerable own key not yielded");

print("forin_shadow: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
