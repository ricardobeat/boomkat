print("Test: typeof Promise");
print(typeof Promise);

print("Test: Promise.resolve");
var p1 = Promise.resolve(42);
print(typeof p1);
print(p1 instanceof Promise);

print("Test: Promise.reject");
var p2 = Promise.reject("err");
print(typeof p2);
print(p2 instanceof Promise);

print("Test: instance .then");
print(typeof p1.then);

print("Test: instance .catch");
print(typeof p1.catch);

print("Test: instance .finally");
print(typeof p1.finally);

print("Test: Promise.length");
print(Promise.length);

print("Test: new Promise");
var p3 = new Promise(function(resolve) { resolve(1); });
print(typeof p3);
print(p3 instanceof Promise);

print("Test: Promise.all");
var pAll = Promise.all([1, 2, 3]);
print(typeof pAll);
print(pAll instanceof Promise);

print("Test: Promise.race");
var pRace = Promise.race([]);
print(typeof pRace);
print(pRace instanceof Promise);

print("Test: thenable chain");
Promise.resolve(10).then(function(v) { print("resolved with", v); });

print("All tests passed");
