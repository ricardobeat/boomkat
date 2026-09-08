// arr_set_length_or_throw re-checked for an inherited non-writable "length"
// only on obj.prototype, one level up. ES2022 §10.1.9.2 OrdinarySet recurses
// into the whole prototype chain, so a non-writable "length" on a grandparent
// must reject too -- instead it fell through and silently defined a new own
// "length" on the instance.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

function outcome(fn) {
    try {
        fn();
    } catch (e) {
        return e.constructor.name;
    }
    return "no throw";
}

function poison(obj, descriptor) {
    Object.defineProperty(obj, "length", descriptor);
}

// Two levels up: Leaf.prototype -> Base.prototype (non-writable length).
{
    class Base {}
    poison(Base.prototype, { writable: false, configurable: true, value: 4 });
    class Derived extends Base {}
    Derived.from = Array.from;
    check("a non-writable length on a grandparent rejects", outcome(function () {
        Derived.from([]);
    }), "TypeError");
}

// One level up still rejects (the case the original check covered).
{
    function Ctor() {}
    poison(Ctor.prototype, { writable: false, configurable: true, value: 4 });
    Ctor.from = Array.from;
    check("a non-writable length on the parent rejects", outcome(function () {
        Ctor.from([]);
    }), "TypeError");
}

// A writable "length" nearer the instance shadows the frozen one above it,
// so the walk must stop at the first property it finds.
{
    class Base {}
    poison(Base.prototype, { writable: false, configurable: true, value: 4 });
    class Mid extends Base {}
    poison(Mid.prototype, { writable: true, configurable: true, value: 0 });
    class Leaf extends Mid {}
    Leaf.from = Array.from;
    check("a writable length shadows a frozen one above it", outcome(function () {
        Leaf.from([]);
    }), "no throw");
}

// An accessor nearer the instance shadows it as well.
{
    class Base {}
    poison(Base.prototype, { writable: false, configurable: true, value: 4 });
    class Mid extends Base {}
    poison(Mid.prototype, { set: function () {}, configurable: true });
    class Leaf extends Mid {}
    Leaf.from = Array.from;
    check("an accessor shadows a frozen length above it", outcome(function () {
        Leaf.from([]);
    }), "no throw");
}

// Ordinary arrays are unaffected.
{
    check("Array.from on a plain array still works", Array.from([1, 2, 3]).join(","), "1,2,3");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
