// Array splice, slice, concat
// Tests Array.prototype.splice, slice, concat, push, pop, shift, unshift.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// splice: remove elements
var a = [1, 2, 3, 4, 5];
var removed = a.splice(2, 2);
assert(removed.join(",") === "3,4", "splice removes 3,4");
assert(a.join(",") === "1,2,5", "array after removal");

// splice: insert elements
var b = [1, 2, 5];
b.splice(2, 0, 3, 4);
assert(b.join(",") === "1,2,3,4,5", "splice inserts 3,4");

// splice: replace elements
var c = ["a", "b", "c", "d"];
c.splice(1, 2, "X", "Y", "Z");
assert(c.join(",") === "a,X,Y,Z,d", "splice replace 2 with 3");

// splice from negative index
var d = [1, 2, 3, 4, 5];
d.splice(-2, 1);
assert(d.join(",") === "1,2,3,5", "splice from -2 removes 4");

// splice: remove all from index
var e = [1, 2, 3, 4, 5];
e.splice(1);
assert(e.join(",") === "1", "splice from 1 removes rest");

// slice
var s = [10, 20, 30, 40, 50];
assert(s.slice(1, 3).join(",") === "20,30", "slice(1,3)");
assert(s.slice(2).join(",") === "30,40,50", "slice(2)");
assert(s.slice(-2).join(",") === "40,50", "slice(-2)");
assert(s.slice().join(",") === "10,20,30,40,50", "slice() clone");
// Original unchanged
assert(s.join(",") === "10,20,30,40,50", "slice doesn't modify");

// concat
var x = [1, 2];
var y = [3, 4];
var z = [5, 6];
assert(x.concat(y).join(",") === "1,2,3,4", "concat two");
assert(x.concat(y, z).join(",") === "1,2,3,4,5,6", "concat three");
assert(x.concat(99).join(",") === "1,2,99", "concat with scalar");
// Original unchanged
assert(x.join(",") === "1,2", "concat doesn't modify");

// push / pop
var stack = [];
stack.push("a");
stack.push("b");
stack.push("c");
assert(stack.length === 3, "push length 3");
assert(stack.pop() === "c", "pop c");
assert(stack.pop() === "b", "pop b");
assert(stack.length === 1, "after pop length 1");

// shift / unshift (queue)
var queue = [];
queue.unshift(1);
queue.unshift(2);
queue.unshift(3);
assert(queue.join(",") === "3,2,1", "unshift order");
assert(queue.shift() === 3, "shift first");
assert(queue.shift() === 2, "shift second");
assert(queue.length === 1, "after shifts length 1");

// join and reverse
var r = [1, 2, 3, 4, 5];
r.reverse();
assert(r.join(",") === "5,4,3,2,1", "reverse");
r.reverse();
assert(r.join(",") === "1,2,3,4,5", "reverse back");

// sort
var unsorted = [3, 1, 4, 1, 5, 9, 2, 6];
unsorted.sort();
assert(unsorted.join(",") === "1,1,2,3,4,5,6,9", "sort numeric strings?");
// Numeric sort with comparator
var nums = [3, 1, 4, 1, 5, 9, 2, 6];
nums.sort(function(a, b) { return a - b; });
assert(nums.join(",") === "1,1,2,3,4,5,6,9", "sort with comparator");

print("engine/array_splice: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
