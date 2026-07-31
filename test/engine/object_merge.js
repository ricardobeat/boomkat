// Object merging and cloning
// Tests shallow/deep copy patterns, Object.keys iteration, property copying.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Shallow copy via loop
function shallowCopy(src) {
    var dest = {};
    for (var k in src) {
        if (src.hasOwnProperty(k)) {
            dest[k] = src[k];
        }
    }
    return dest;
}

var orig = { a: 1, b: "hello", c: true };
var copy = shallowCopy(orig);
assert(copy.a === 1 && copy.b === "hello" && copy.c === true, "shallow copy values");
assert(copy !== orig, "different object reference");

// Shallow copy shares nested objects
var nested = { x: 1, y: [1, 2, 3] };
var nc = shallowCopy(nested);
assert(nc.x === 1, "nested copy value");
nc.x = 99;
assert(nested.x === 1, "primitive independent");
nc.y.push(4);
assert(nested.y.length === 4, "array is shared (shallow)");

// Deep copy via JSON roundtrip
function deepCopy(obj) {
    return JSON.parse(JSON.stringify(obj));
}

var deep = { name: "test", data: { items: [1, 2, 3], meta: { count: 3 } } };
var dc = deepCopy(deep);
assert(dc.name === "test", "deep copy name");
assert(dc.data.items.length === 3, "deep copy items");
dc.data.items.push(4);
assert(deep.data.items.length === 3, "deep copy independent");

// Merge objects
function merge(dest, src) {
    for (var k in src) {
        if (src.hasOwnProperty(k)) {
            dest[k] = src[k];
        }
    }
    return dest;
}

var base = { a: 1, b: 2 };
var extra = { b: 99, c: 3 };
var merged = merge(base, extra);
assert(merged.a === 1, "merged keeps a");
assert(merged.b === 99, "merged overwrites b");
assert(merged.c === 3, "merged adds c");
assert(merged === base, "merge modifies dest in-place");

// Multi-source merge
function mergeAll() {
    var result = {};
    for (var i = 0; i < arguments.length; i++) {
        var src = arguments[i];
        for (var k in src) {
            if (src.hasOwnProperty(k)) result[k] = src[k];
        }
    }
    return result;
}

var m1 = { a: 1 };
var m2 = { b: 2 };
var m3 = { c: 3, a: 99 };
var all = mergeAll(m1, m2, m3);
assert(all.a === 99, "last source wins");
assert(all.b === 2, "from m2");
assert(all.c === 3, "from m3");

// Clone array
function cloneArray(arr) {
    return arr.slice(0);
}
var origArr = [1, 2, 3];
var clonedArr = cloneArray(origArr);
assert(clonedArr.join(",") === "1,2,3", "cloned array values");
clonedArr.push(4);
assert(origArr.length === 3, "original unaffected");

// Property count helper
function propCount(obj) {
    var count = 0;
    for (var k in obj) {
        if (obj.hasOwnProperty(k)) count++;
    }
    return count;
}
assert(propCount({}) === 0, "empty has 0 props");
assert(propCount({ a: 1, b: 2, c: 3 }) === 3, "3 props");

// hasOwnProperty on created object
var proto = { inherited: true };
var inst = Object.create(proto);
inst.own = 42;
assert(inst.hasOwnProperty("own"), "hasOwnProperty own");
assert(!inst.hasOwnProperty("inherited"), "hasOwnProperty inherited");
assert(inst.inherited === true, "inherited accessible");

print("engine/object_merge: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
