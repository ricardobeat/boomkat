// Test Promise basic functionality

print("=== Promise constructor ===");
print(typeof Promise); // Should be "function"

print("");
print("=== Promise.resolve ===");
var p1 = Promise.resolve(42);
print(typeof p1); // Should be "object"

print("");
print("=== Promise.reject ===");
var p2 = Promise.reject("error");
p2.catch(function(){});
print(typeof p2); // Should be "object"

print("");
print("=== Promise.prototype.then ===");
var thenType = typeof Promise.prototype.then;
print(thenType); // Should be "function"

print("");
print("=== Promise.prototype.catch ===");
var catchType = typeof Promise.prototype.catch;
print(catchType); // Should be "function"

print("");
print("=== new Promise ===");
var p3 = new Promise(function(resolve, reject) {
    print("executor called");
    resolve("done");
});
print(typeof p3); // Should be "object"

print("");
print("=== Promise.length ===");
print(Promise.length); // Should be 1

print("");
print("=== instanceof Promise ===");
print(p1 instanceof Promise); // Should be true
print(p3 instanceof Promise); // Should be true

print("");
print("=== [object Promise] ===");
var p4 = new Promise(function(r) { r(1); });
print(Object.prototype.toString.call(p4)); // Should be [object Promise]

print("");
print("=== Promise.all (stub) ===");
var pall = Promise.all([1, 2, 3]);
print(typeof pall); // Should be object
print(pall instanceof Promise); // Should be true

print("");
print("=== Promise.race (stub) ===");
var prace = Promise.race([1, 2]);
print(typeof prace); // Should be object
print(prace instanceof Promise); // Should be true

print("");
print("=== All Promise tests passed ===");
