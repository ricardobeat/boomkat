// Two distinct Array.prototype bugs found via the SM to-length.js / fill.js
// tests:
//
// 1. Array.prototype.map (and friends sharing array_species_create_result)
//    threw RangeError for a length > 2^32-1 BEFORE ever consulting the
//    receiver's species constructor. Per ES2022 §9.4.2.3 ArraySpeciesCreate,
//    that RangeError belongs only to the fallback ArrayCreate(len) path
//    (§9.4.2.2 step 1) -- a custom species constructor is called with the
//    full ToLength'd length regardless, and may do anything with it
//    (including throw its own error, or ignore it and succeed).
//
// 2. array_set_elem_ulong_set (the shared numeric-index [[Set]] used by
//    fill/sort/reverse/copyWithin/etc. on any array-like `this`) had no
//    STRING-exotic case. A String wrapper's in-range character indices are
//    non-writable, non-configurable own data properties (ES2022 §10.4.3.5
//    StringGetOwnProperty) -- [[Set]] must fail there -- but since character
//    properties are served lazily (never materialised as real own
//    properties), the "own property" lookup found nothing and silently fell
//    through to DEFINING a new one instead of throwing.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// --- 1: species constructor must be consulted before any RangeError ---
{
    const max = Number.MAX_SAFE_INTEGER;
    var seenLength;
    var proxy = new Proxy([], {
        get(target, property) {
            if (property === "length") return Infinity;
            function fakeConstructor(length) {
                seenLength = length;
                throw "invoked";
            }
            fakeConstructor[Symbol.species] = fakeConstructor;
            return fakeConstructor;
        },
    });
    var caught;
    try {
        Array.prototype.map.call(proxy, () => {});
    } catch (e) {
        caught = e;
    }
    check("species constructor is called (not short-circuited by RangeError)", caught, "invoked");
    check("species constructor receives ToLength(Infinity) = MAX_SAFE_INTEGER", seenLength, max);
}

// --- 1b: with no species constructor, an oversized length still throws RangeError ---
{
    var threw = false;
    try {
        Array.prototype.map.call({ length: Number.MAX_SAFE_INTEGER }, () => {});
    } catch (e) {
        threw = e instanceof RangeError;
    }
    check("plain array-like with oversized length still throws RangeError", threw, true);
}

// --- 2: writing a numeric index on a String primitive `this` must throw ---
{
    var threw = false;
    try {
        [].fill.call("111", 2);
    } catch (e) {
        threw = e instanceof TypeError;
    }
    check("Array.prototype.fill.call(stringPrimitive, ...) throws TypeError", threw, true);
}

// --- 2b: out-of-range indices on a String `this` are unaffected (still define normally) ---
{
    var s = Object("ab");
    s[5] = "x";
    check("out-of-range index write on a String object still succeeds", s[5], "x");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
