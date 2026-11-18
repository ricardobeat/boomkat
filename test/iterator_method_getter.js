// GetIterator reads @@iterator with [[Get]], so an accessor's getter runs, with
// the receiver as `this`. The Map/Set/WeakMap/WeakSet constructors and
// Object.fromEntries read the raw slot instead, found no callable there and
// threw "not iterable" (or, for fromEntries, fell back to other paths).

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

var gen = function* () { yield [1, 2]; yield [3, 4]; };
function viaGetter() { return { get [Symbol.iterator]() { return gen; } }; }

check("Set", new Set(viaGetter()).size, 2);
check("Map", new Map(viaGetter()).get(3), 4);
check("WeakSet", new WeakSet({ get [Symbol.iterator]() { return function* () { yield {}; }; } }) instanceof WeakSet, true);
var key = {};
check("WeakMap", new WeakMap({ get [Symbol.iterator]() { return function* () { yield [key, 7]; }; } }).get(key), 7);
check("Object.fromEntries", JSON.stringify(Object.fromEntries(viaGetter())), '{"1":2,"3":4}');

// The getter's `this` is the receiver, not the prototype holding it.
var seen = null;
var holder = { get [Symbol.iterator]() { seen = this; return gen; } };
var child = Object.create(holder);
new Set(child);
check("getter receiver", seen === child, true);

// A throwing getter's error and a non-callable result surface.
var caught = "";
try { new Set({ get [Symbol.iterator]() { throw new RangeError("set"); } }); } catch (e) { caught += e.name + ":" + e.message; }
try { Object.fromEntries({ get [Symbol.iterator]() { throw new RangeError("fe"); } }); } catch (e) { caught += " " + e.name + ":" + e.message; }
try { new Map({ get [Symbol.iterator]() { return 5; } }); } catch (e) { caught += " " + e.name; }
check("throws", caught, "RangeError:set RangeError:fe TypeError");

if (failures === 0) print("iterator_method_getter: ok");
