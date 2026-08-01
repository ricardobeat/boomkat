// Shape-ID exhaustion
// Shape IDs are a global, monotonically growing counter, so a program that
// creates enough distinct property layouts crosses the old 16-bit ceiling.
// Every read below must still be correct on both sides of that crossing.
// Runtime is roughly 100ms.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// --- 1. Well over 65534 shape transitions spread across many objects --------
// Each object uses keys unique to itself, so no transition is ever shared and
// the global shape counter advances once per write. 800 x 100 = 80000
// transitions, while no single object holds more than 100 properties. That
// isolates the global shape-ID space from any per-object property limit: this
// section fails even though every individual object stays small.
var OBJS = 800, PER = 100;
var objs = [];
for (var o = 0; o < OBJS; o++) {
    var obj = {};
    for (var k = 0; k < PER; k++) obj["o" + o + "_k" + k] = o * 1000 + k;
    objs.push(obj);
}

var bad = 0;
for (var o = 0; o < OBJS; o++) {
    for (var k = 0; k < PER; k++) {
        if (objs[o]["o" + o + "_k" + k] !== o * 1000 + k) bad++;
    }
}
assert(bad === 0, "all " + (OBJS * PER) + " reads correct, got " + bad + " wrong");

// The count is global, so objects created late must be as healthy as early
// ones. Before the fix the last object read back as completely empty.
assert(Object.keys(objs[0]).length === PER, "first object keeps its keys");
assert(Object.keys(objs[OBJS - 1]).length === PER, "last object keeps its keys");

// --- 2. Objects created after the crossing still work ----------------------
// Exhaustion used to be permanent and process-wide: every later object was
// stuck at the root shape, so named writes vanished silently.
var fresh = {};
fresh.a = 1;
fresh.b = 2;
assert(fresh.a === 1, "fresh object property a");
assert(fresh.b === 2, "fresh object property b");
assert(Object.keys(fresh).length === 2, "fresh object key count");
assert(JSON.stringify(fresh) === '{"a":1,"b":2}', "fresh object serializes");
assert(fresh.hasOwnProperty("a"), "fresh object hasOwnProperty");
delete fresh.a;
assert(!fresh.hasOwnProperty("a"), "delete after crossing");
assert(fresh.b === 2, "surviving property after delete");

// A prototype lookup still resolves once the shape space is well past 65534.
var proto = { inherited: 42 };
var child = Object.create(proto);
child.own = 7;
assert(child.inherited === 42, "inherited property after crossing");
assert(child.own === 7, "own property after crossing");

// --- 3. One object holding more than 65535 properties ----------------------
// The property table is indexed separately from shape IDs; both used to be
// 16-bit. Writes past the limit were dropped while reporting success, so this
// checks the boundary keys directly as well as the whole range.
var big = {};
var BIG_N = 70000;
for (var i = 0; i < BIG_N; i++) big["p" + i] = i;
assert(big["p0"] === 0, "big object first key");
assert(big["p65534"] === 65534, "big object at the old ceiling");
assert(big["p65535"] === 65535, "big object just past the old ceiling");
assert(big["p" + (BIG_N - 1)] === BIG_N - 1, "big object last key");

var bigBad = 0;
for (var i = 0; i < BIG_N; i++) if (big["p" + i] !== i) bigBad++;
assert(bigBad === 0, "all big-object reads correct, got " + bigBad + " wrong");

// --- 4. Inline caches stay correct across the crossing ---------------------
// A polymorphic site sees many shapes. A cache that aliased two shape IDs, or
// truncated a property index, would return another object's value here.
function readX(obj) { return obj.x; }
var icBad = 0;
for (var i = 0; i < 500; i++) {
    var t = {};
    t["u" + i] = i;   // unique key first, so every t gets its own fresh shape
    t.x = i * 7;      // shared final key, reached from a distinct parent shape
    if (readX(t) !== i * 7) icBad++;
}
assert(icBad === 0, "inline cache correct across shapes, got " + icBad + " wrong");

print("engine/shape_id_exhaustion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
