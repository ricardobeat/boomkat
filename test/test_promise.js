// Test Promise basic functionality (no prototype chain — methods accessed via
// Promise as a class and via instance p.then/catch).
print("=== Promise constructor ===");
print(typeof Promise);

print("=== Promise.resolve ===");
var p1 = Promise.resolve(42);
print(typeof p1);
print(p1 instanceof Promise);

print("=== Promise.reject ===");
var p2 = Promise.reject("error");
print(typeof p2);
print(p2 instanceof Promise);

print("=== instance .then/.catch ===");
var p3 = new Promise(function(resolve, reject) {
    resolve("done");
});
print(typeof p3.then);
print(typeof p3.catch);

print("=== new Promise ===");
var p4 = new Promise(function(resolve, reject) {
    resolve("done");
});
print(typeof p4);
print(p4 instanceof Promise);

print("=== Promise.length ===");
print(Promise.length);

print("=== instanceof Promise ===");
print(p1 instanceof Promise);
print(p3 instanceof Promise);

print("=== Promise.all ===");
var pall = Promise.all([1, 2, 3]);
print(typeof pall);
print(pall instanceof Promise);

print("=== Promise.race ===");
var prace = Promise.race([1, 2]);
print(typeof prace);
print(prace instanceof Promise);

print("=== then chain ===");
var chain = Promise.resolve(1).then(function(v) { return v + 1; });
print(typeof chain);
print(chain instanceof Promise);

print("=== All Promise tests passed ===");
