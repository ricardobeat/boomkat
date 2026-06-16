// Async/await tests for TinyDuck

// Test 1: async function returns a Promise
async function simple() {
    return 42;
}
var p1 = simple();
print(typeof p1);  // "object"

// Test 2: await on non-promise value passes through
async function await_val() {
    return await 99;
}
var p2 = await_val();
print(typeof p2);  // "object"

// Test 3: async function with computation
async function compute() {
    var x = await 10;
    return x + 5;
}
var p3 = compute();
print(typeof p3);  // "object"

// Test 4: await on already-resolved promise
async function await_resolved() {
    var v = await Promise.resolve("hello");
    return v;
}
var p4 = await_resolved();
print(typeof p4);  // "object"

print("All async tests compiled successfully");
