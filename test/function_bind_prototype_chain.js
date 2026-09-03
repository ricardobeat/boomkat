// Function.prototype.bind must give the bound function target's own
// [[Prototype]] (ES2022 §10.4.1.3 BoundFunctionCreate step 2:
// proto = ? target.[[GetPrototypeOf]]()), not the fixed Function.prototype.
// This matters when the target is itself a subclass of Function (via
// `class C extends Function {}`) or otherwise has a custom .prototype:
// bound instances must keep the same [[Prototype]] chain so `instanceof`
// still recognizes them.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- subclassing Function ---
class func extends Function {}
var inst = new func("x", "return this.bar + x");
var bound = inst.bind({ bar: 3 }, 4);
check("bound instance keeps target's [[Prototype]]", bound instanceof func, true);
check("bound function still callable", bound(), 7);

// --- a target with a null [[Prototype]] ---
Object.setPrototypeOf(inst, null);
var bound2 = Function.prototype.bind.call(inst, { bar: 1 }, 3);
check("bound instance of null-proto target has null proto", Object.getPrototypeOf(bound2), null);
check("still callable with null proto", bound2(), 4);

// --- plain function keeps the ordinary Function.prototype ---
function plain() {}
var bound3 = plain.bind(null);
check("plain function bind keeps Function.prototype", Object.getPrototypeOf(bound3), Function.prototype);

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
