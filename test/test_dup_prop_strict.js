// Duplicate property names in object literals.
// ES5 §11.1.5 made duplicate data properties a SyntaxError in strict mode.
// ES2015 §12.2.6 REMOVED that restriction entirely: a duplicate key is now
// always legal and the last value simply wins, in strict mode as in sloppy.
// The one duplicate that is still an early SyntaxError is `__proto__: value`
// appearing twice (ES2015 §12.2.6.1), because that form sets [[Prototype]]
// rather than defining an own property.
// Our engine is strict-only, so all code runs in strict mode.

// Test 1: Duplicate data property name is legal; last value wins
try {
    var o1 = eval("({a: 1, a: 2})");
    if (o1.a === 2) {
        print("PASS: test1 - duplicate data property keeps last value");
    } else {
        print("FAIL: test1 - expected a === 2, got " + o1.a);
    }
} catch (e) {
    print("FAIL: test1 - unexpected error: " + e.message);
}

// Test 2: Duplicate numeric property names are legal; last value wins
try {
    var o2 = eval("({0: 1, 0: 2})");
    if (o2[0] === 2) {
        print("PASS: test2 - duplicate numeric property keeps last value");
    } else {
        print("FAIL: test2 - expected [0] === 2, got " + o2[0]);
    }
} catch (e) {
    print("FAIL: test2 - unexpected error: " + e.message);
}

// Test 3: Numeric and string equivalent keys collapse to one property
try {
    var o3 = eval("({0: 1, '0': 2})");
    if (o3[0] === 2 && Object.keys(o3).length === 1) {
        print("PASS: test3 - numeric '0' and string '0' are the same key");
    } else {
        print("FAIL: test3 - got [0]=" + o3[0] + " keys=" + Object.keys(o3).length);
    }
} catch (e) {
    print("FAIL: test3 - unexpected error: " + e.message);
}

// Test 3a: Duplicate `__proto__: value` is still an early SyntaxError
try {
    eval("({__proto__: null, __proto__: null})");
    print("FAIL: test3a - duplicate __proto__ should throw SyntaxError");
} catch (e) {
    if (e instanceof SyntaxError) {
        print("PASS: test3a - duplicate __proto__ throws SyntaxError");
    } else {
        print("FAIL: test3a - expected SyntaxError, got " + e.constructor.name);
    }
}

// Test 3b: A single `__proto__: value` sets the prototype, and the other
// property forms named __proto__ are exempt from the duplicate rule
try {
    var o3b = eval("({__proto__: null})");
    var okProto = Object.getPrototypeOf(o3b) === null;
    // computed / shorthand / method keys define own properties instead
    eval("({['__proto__']: 1, __proto__: null})");
    eval("({__proto__: null, __proto__() {}})");
    eval("({__proto__: null, get __proto__() {}})");
    if (okProto) {
        print("PASS: test3b - single __proto__ sets prototype, other forms exempt");
    } else {
        print("FAIL: test3b - prototype not set to null");
    }
} catch (e) {
    print("FAIL: test3b - unexpected error: " + e.message);
}

// Test 4: Non-duplicate property names should not throw
try {
    var o = {a: 1, b: 2};
    if (o.a === 1 && o.b === 2) {
        print("PASS: test4 - non-duplicate properties work");
    } else {
        print("FAIL: test4 - wrong values");
    }
} catch (e) {
    print("FAIL: test4 - unexpected error: " + e.message);
}

// Test 5: Computed property keys should not trigger duplicate check
try {
    var k = "a";
    var o = {a: 1, [k]: 2};
    if (o.a === 2) {
        print("PASS: test5 - computed property overwrites statically");
    } else {
        print("FAIL: test5 - wrong value for o.a: " + o.a);
    }
} catch (e) {
    print("FAIL: test5 - unexpected error: " + e.message);
}

// Test 6: Method shorthand should not trigger duplicate check with data property
try {
    var o = {a: 1, b() { return 2; }};
    if (o.a === 1 && o.b() === 2) {
        print("PASS: test6 - data + method with different names work");
    } else {
        print("FAIL: test6 - wrong values");
    }
} catch (e) {
    print("FAIL: test6 - unexpected error: " + e.message);
}

// Test 7: Single property no duplicate
try {
    var o = {a: 1};
    if (o.a === 1) {
        print("PASS: test7 - single property works");
    } else {
        print("FAIL: test7 - wrong value");
    }
} catch (e) {
    print("FAIL: test7 - unexpected error: " + e.message);
}

// Test 8: Empty object
try {
    var o = {};
    if (typeof o === "object") {
        print("PASS: test8 - empty object works");
    } else {
        print("FAIL: test8 - wrong type");
    }
} catch (e) {
    print("FAIL: test8 - unexpected error: " + e.message);
}

print("Done - duplicate property tests");
