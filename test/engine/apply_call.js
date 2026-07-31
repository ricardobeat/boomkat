// Function apply and call
// Tests Function.prototype.apply, .call, method borrowing.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic apply
function add(a, b) { return a + b; }
assert(add.apply(null, [3, 4]) === 7, "apply with array");
assert(add.call(null, 3, 4) === 7, "call with args");

// apply to spread array as args
function multiply(a, b, c) { return a * b * c; }
var nums = [2, 3, 4];
assert(multiply.apply(null, nums) === 24, "apply spreads array");

// call with explicit this
var printer = {
    prefix: "Hello, ",
    greet: function(name) { return this.prefix + name; }
};
assert(printer.greet("World") === "Hello, World", "normal method call");

var other = { prefix: "Hi, " };
assert(printer.greet.call(other, "JS") === "Hi, JS", "call changes this");
assert(printer.greet.apply(other, ["C"]) === "Hi, C", "apply changes this");

// Borrowing hasOwnProperty
var obj = { a: 1 };
assert(Object.prototype.hasOwnProperty.call(obj, "a"), "borrowed hasOwnProperty");

// Math.max with apply
var max = Math.max.apply(null, [3, 1, 4, 1, 5, 9, 2, 6]);
assert(max === 9, "Math.max via apply");

var min = Math.min.apply(null, [3, 1, 4, 1, 5, 9, 2, 6]);
assert(min === 1, "Math.min via apply");

// Constructor with apply
function Point(x, y) { this.x = x; this.y = y; }
var p = new (Function.prototype.bind.apply(Point, [null, 10, 20]))();
assert(p.x === 10 && p.y === 20, "constructor via apply");

// Concat arrays with apply
var a1 = [1, 2];
var a2 = [3, 4];
var merged = Array.prototype.concat.apply(a1, a2);
assert(merged.length === 4, "concat via apply length");
assert(merged[3] === 4, "concat via apply last");

print("engine/apply_call: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
