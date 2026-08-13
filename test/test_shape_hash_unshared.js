// Shape hash tables must not be built per shape on an unshared chain.
//
// The property hash table lives on the Shape and is built lazily once an
// object reaches 8 properties. Every put_prop moves the object to a NEW
// shape, so an object whose shapes nobody else uses would build one table
// per property, each covering the whole chain: O(N^2) memory and time for a
// single object. Building 800 properties that way cost about a gigabyte and
// wedged test/engine/shape_id_exhaustion.js, which the OOM killer stopped
// before it could print anything.
//
// Only a shape a second object actually reaches can amortize a table, so
// that is the condition for building one. This test covers both sides: the
// unshared chain stays cheap and correct, and the shared shape still answers
// lookups correctly once several objects arrive at it.
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}

// --- Unshared chain, well past the 8-property threshold ---------------------
// Keys are unique to this object, so no other object ever takes these
// transitions. Before the fix this allocated a table per property.
var deep = {};
var DEEP = 400;
for (var i = 0; i < DEEP; i++) { deep["uniq_" + i] = i; }

var bad = 0;
for (var i = 0; i < DEEP; i++) { if (deep["uniq_" + i] !== i) { bad++; } }
ok(bad === 0, "all " + DEEP + " unshared-chain reads correct, " + bad + " wrong");
ok(Object.keys(deep).length === DEEP, "unshared chain keeps every key");

// --- Many objects converging on one shared shape ----------------------------
// These all take the same transitions, so the shape becomes shared and does
// build a table. Every object must still read back its own values.
function make(v) {
    var o = {};
    o.a = v; o.b = v + 1; o.c = v + 2; o.d = v + 3;
    o.e = v + 4; o.f = v + 5; o.g = v + 6; o.h = v + 7;
    o.i = v + 8; o.j = v + 9;
    return o;
}
var objs = [];
for (var i = 0; i < 50; i++) { objs.push(make(i * 100)); }

var sharedBad = 0;
for (var i = 0; i < objs.length; i++) {
    var base = i * 100;
    var o = objs[i];
    if (o.a !== base || o.e !== base + 4 || o.j !== base + 9) { sharedBad++; }
}
ok(sharedBad === 0, "shared-shape reads correct, " + sharedBad + " objects wrong");

// --- The same key set reached by two different insertion orders -------------
// Two objects with identical keys added in opposite orders get different
// shapes. Neither may answer with the other's indexes.
function build(order) {
    var o = {};
    for (var i = 0; i < order.length; i++) { o[order[i]] = order[i]; }
    return o;
}
var keys = ["k0","k1","k2","k3","k4","k5","k6","k7","k8","k9"];
var rev = keys.slice().reverse();
var fwd = build(keys);
var bwd = build(rev);
var orderBad = 0;
for (var i = 0; i < keys.length; i++) {
    if (fwd[keys[i]] !== keys[i]) { orderBad++; }
    if (bwd[keys[i]] !== keys[i]) { orderBad++; }
}
ok(orderBad === 0, "insertion order forks read correctly, " + orderBad + " wrong");

// --- Cross the threshold, delete back under it, then re-add -----------------
// delete gives the object a fresh private shape, so any table built for the
// old one must not survive to answer with stale indexes.
var churn = {};
for (var i = 0; i < 12; i++) { churn["c" + i] = i; }
for (var i = 4; i < 10; i++) { delete churn["c" + i]; }
ok(churn.c0 === 0, "survivor below the deleted range keeps its value");
ok(churn.c11 === 11, "survivor above the deleted range keeps its value");
ok(churn.c5 === undefined, "deleted key reads undefined");
for (var i = 4; i < 10; i++) { churn["c" + i] = i * 10; }
ok(churn.c5 === 50, "re-added key reads its new value");
ok(churn.c11 === 11, "untouched key survives the re-add");

print("pass: " + pass + ", fail: " + fail);
