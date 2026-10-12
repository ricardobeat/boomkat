function check(value, expected) {
    if (value !== expected) throw new Error("FAIL species guard: " + value);
}
for (var i = 0; i < 10; i++) Promise.resolve(i).then();
var ctorDescriptor = Object.getOwnPropertyDescriptor(Promise.prototype, "constructor");
var speciesDescriptor = Object.getOwnPropertyDescriptor(Promise, Symbol.species);
var reads = 0;
Object.defineProperty(Promise.prototype, "constructor", {
    configurable: true, get: function () { reads++; return Promise; }
});
Promise.resolve(1).then();
check(reads, 1);
Object.defineProperty(Promise.prototype, "constructor", ctorDescriptor);
Promise.resolve(1).then();
Object.defineProperty(Promise, Symbol.species, {
    configurable: true, get: function () { reads++; return Promise; }
});
Promise.resolve(1).then();
check(reads, 2);
Object.defineProperty(Promise, Symbol.species, speciesDescriptor);
var own = Promise.resolve(1);
Object.defineProperty(own, "constructor", { get: function () { reads++; return Promise; } });
own.then();
check(reads, 3);
Promise.prototype.constructor = { get [Symbol.species]() { reads++; return Promise; } };
Promise.resolve(1).then();
check(reads, 4);
Object.defineProperty(Promise.prototype, "constructor", ctorDescriptor);
var failure = {};
Object.defineProperty(Promise, Symbol.species, { configurable: true, get: function () { throw failure; } });
var caught;
try { Promise.resolve(1).then(); } catch (e) { caught = e; }
check(caught, failure);
Object.defineProperty(Promise, Symbol.species, speciesDescriptor);
Promise.resolve(1).then();
print("PASS promise species guard");
