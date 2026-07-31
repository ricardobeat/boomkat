// Map function (higher-order)

function myMap(arr, fn) {
    var result = [];
    for (var i = 0; i < arr.length; i++) {
        result.push(fn(arr[i], i));
    }
    return result;
}

function arrayEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) return false; }
    return true;
}

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

assert(arrayEq(myMap([1,2,3], function(x){ return x*2; }), [2,4,6]), "double");
assert(arrayEq(myMap([1,2,3], function(x){ return x*x; }), [1,4,9]), "square");
assert(arrayEq(myMap([], function(x){ return x; }), []), "empty");
assert(arrayEq(myMap(["a","b","c"], function(x,i){ return x+i; }), ["a0","b1","c2"]), "with index");

// Nested map
var nested = myMap([1,2,3], function(x) {
    return myMap([10,20], function(y) { return x + y; });
});
assert(nested[0][0] === 11, "nested[0][0]=11, got " + nested[0][0]);
assert(nested[2][1] === 23, "nested[2][1]=23, got " + nested[2][1]);

print("engine/map_function: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
