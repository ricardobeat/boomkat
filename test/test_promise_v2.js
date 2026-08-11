print("Test 1: typeof Promise");
print(typeof Promise);

print("Test 2: typeof Promise.prototype.then");
print(typeof Promise.prototype.then);

print("Test 3: typeof Promise.prototype.catch");
print(typeof Promise.prototype.catch);

print("Test 4: Promise.length");
print(Promise.length);

print("Test 5: Promise.resolve returns promise");
var p1 = Promise.resolve(42);
print(typeof p1);
print(p1 instanceof Promise);

print("Test 6: Promise.reject returns promise");
var p2 = Promise.reject("error");
p2.catch(function(){});
print(typeof p2);
print(p2 instanceof Promise);

print("Test 7: new Promise with executor");
var p3 = new Promise(function(resolve, reject) {
    print("  executor called");
    resolve("done");
});
print(typeof p3);

print("Test 8: toString tag");
print(Object.prototype.toString.call(p1));

print("All tests done");
