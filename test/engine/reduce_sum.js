// Sum of a series / Reduce

function reduce(arr, fn, init) {
    var acc = init;
    for (var i = 0; i < arr.length; i++) {
        acc = fn(acc, arr[i], i);
    }
    return acc;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var sum = reduce([1,2,3,4,5], function(a,b){ return a+b; }, 0);
assert(sum === 15, "sum 1..5=15, got " + sum);

var product = reduce([1,2,3,4,5], function(a,b){ return a*b; }, 1);
assert(product === 120, "product 1..5=120, got " + product);

var empty = reduce([], function(a,b){ return a+b; }, 42);
assert(empty === 42, "empty with init=42");

var concat = reduce(["a","b","c"], function(a,b){ return a+b; }, "");
assert(concat === "abc", "concat 'abc', got '" + concat + "'");

// Use reduce to build object
var obj = reduce([["a",1],["b",2]], function(acc,pair){
    acc[pair[0]] = pair[1]; return acc;
}, {});
assert(obj.a === 1 && obj.b === 2, "build object from pairs");

print("engine/reduce_sum: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
