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

print("Test: Promise.prototype");
var proto = Promise.prototype;
print(typeof proto);

print("Test: Promise.prototype.then");
var thenFn = Promise.prototype.then;
print(typeof thenFn);

print("Test: Promise.prototype.catch");
var catchFn = Promise.prototype.catch;
print(typeof catchFn);

print("Test: Promise.length");
print(Promise.length);

print("Test: new Promise");
var p3 = new Promise(function(resolve) { resolve(1); });
print(typeof p3);

print("Done");
