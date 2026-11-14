// A loop that carries a parameter gets a phi for it: the parameter is checked as a number on entry.
// A call that passes something else leaves the function's parameters in the window from then on,
// and every call keeps its result.
function sum(i, n, acc) {
    while (--n >= 0) acc += i++;
    return acc;
}
var total = 0;
for (var k = 0; k < 3000; k++) total += sum(k, 20, 0);
if (total !== 3000 * 190 + 20 * (3000 * 2999 / 2)) throw new Error("ints " + total);
// A double start, then a string accumulator and a missing argument: none of them an int32.
if (sum(0.5, 4, 0) !== 8) throw new Error("double");
if (sum(1, 3, "") !== "123") throw new Error("string " + sum(1, 3, ""));
if (!isNaN(sum(undefined, 2, 0))) throw new Error("undefined");
if (sum(1, 0) !== undefined) throw new Error("no iterations");
// The count itself not an int32: a double runs while it stays at or above zero, a string converts.
if (sum(1, 2.5, 0) !== 3) throw new Error("double count " + sum(1, 2.5, 0));
if (sum(1, "3", 0) !== 6) throw new Error("string count " + sum(1, "3", 0));
var again = 0;
for (var k = 0; k < 3000; k++) again += sum(k, 20, 0);
if (again !== total) throw new Error("after " + again);
console.log("ok");
