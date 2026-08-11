print("Test: typeof Promise");
print(typeof Promise);

print("Test: Promise.resolve");
var p1 = Promise.resolve(42);
print(typeof p1);
print(p1 instanceof Promise);

print("Test: Promise.reject");
var p2 = Promise.reject("err");
p2.catch(function(){});
print(typeof p2);
print(p2 instanceof Promise);

print("Test: Promise.prototype.then");
var thenFn = Promise.prototype.then;
print(typeof thenFn);

print("Test: Promise.prototype.catch");
var catchFn = Promise.prototype.catch;
print(typeof catchFn);

print("Test: Promise.prototype.finally");
var finallyFn = Promise.prototype.finally;
print(typeof finallyFn);

print("Test: Promise.length");
print(Promise.length);

print("Test: new Promise");
var p3 = new Promise(function(resolve) { resolve(1); });
print(typeof p3);

print("Test: toString tag");
print(Object.prototype.toString.call(p1));

print("Test: Promise.all");
var pAll = Promise.all([1, 2, 3]);
print(typeof pAll);
print(pAll instanceof Promise);

print("Test: Promise.race");
var pRace = Promise.race([]);
print(typeof pRace);
print(pRace instanceof Promise);

print("All tests passed");
