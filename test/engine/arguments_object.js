// Arguments object
// Tests the 'arguments' object, length, indexed access, conversion.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic arguments
function sum() {
    var total = 0;
    for (var i = 0; i < arguments.length; i++) {
        total += arguments[i];
    }
    return total;
}
assert(sum() === 0, "no args = 0");
assert(sum(1) === 1, "one arg");
assert(sum(1, 2, 3, 4) === 10, "four args");
assert(sum(10, 20, 30, 40, 50) === 150, "five args");

// arguments.length
function argLen() { return arguments.length; }
assert(argLen() === 0, "zero length");
assert(argLen(1, 2) === 2, "two length");
assert(argLen(1, 2, 3, 4, 5, 6, 7, 8) === 8, "eight length");

// arguments is not an array
function isArray() {
    return Array.isArray(arguments);
}
assert(isArray(1, 2) === false, "arguments is not array");

// Named params + arguments
function namedAndExtra(a, b) {
    return [a, b, arguments.length, arguments[2]];
}
var r = namedAndExtra(10, 20, 30);
assert(r[0] === 10 && r[1] === 20, "named params match");
assert(r[2] === 3, "arguments.length includes extra");
assert(r[3] === 30, "extra arg accessible");

// But only in sloppy mode; adding beyond length doesn't affect named
function noAlias(a) {
    arguments[1] = 99;
    return a;
}
assert(noAlias(5) === 5, "arguments[1] doesn't alias a");

// arguments with no corresponding named param
function extra(a) {
    return arguments.length;
}
assert(extra(1, 2, 3, 4, 5) === 5, "counts all args even beyond named");

print("engine/arguments_object: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
