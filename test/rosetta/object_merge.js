// Rosetta Code: Object merging and cloning
// https://rosettacode.org/wiki/Object_copy
// Tests shallow/deep copy patterns, merge helpers, spread. TinyDuck has no
// prototype chain and no `arguments`, so multi-source merge uses rest params
// and the `hasOwnProperty` filters are dropped (for..in already walks own).

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Shallow copy via for..in (walks own props only)
function shallowCopy(src) {
    var dest = {};
    for (var k in src) {
        dest[k] = src[k];
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

// Merge two objects (in-place)
function merge(dest, src) {
    for (var k in src) {
        dest[k] = src[k];
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

// Multi-source merge via rest params (replaces `arguments`)
function mergeAll(...sources) {
    var result = {};
    for (var i = 0; i < sources.length; i++) {
        for (var k in sources[i]) {
            result[k] = sources[i][k];
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

// Clone array via slice
function cloneArray(arr) {
    return arr.slice(0);
}
var origArr = [1, 2, 3];
var clonedArr = cloneArray(origArr);
assert(clonedArr.join(",") === "1,2,3", "cloned array values");
clonedArr.push(4);
assert(origArr.length === 3, "original unaffected");

// Property count helper (own only — for..in already filters)
function propCount(obj) {
    var count = 0;
    for (var k in obj) { count++; }
    return count;
}
assert(propCount({}) === 0, "empty has 0 props");
assert(propCount({ a: 1, b: 2, c: 3 }) === 3, "3 props");

// Merge copy (object spread not supported in TinyDuck)
var src = { a: 1, b: 2 };
var spread = mergeAll(src, { c: 3 });
assert(spread.a === 1 && spread.b === 2 && spread.c === 3, "merge copy");

print("rosetta/object_merge: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
