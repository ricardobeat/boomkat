// Array.prototype.sort converts a comparator's result with ToNumber (SortCompare step 4.b): an
// object's valueOf decides the order and may throw, a Symbol or BigInt result throws a TypeError,
// and NaN compares equal.
function check(name, got, want) {
    if (got !== want) print("FAIL " + name + ": got " + got + ", want " + want);
}

check("valueOf", [3, 1, 2].sort(function (a, b) { return { valueOf: function () { return a - b; } }; }).join(), "1,2,3");
check("toString", [3, 1, 2].sort(function (a, b) { return { toString: function () { return String(b - a); } }; }).join(), "3,2,1");
check("string", [3, 1, 2].sort(function (a, b) { return String(a - b); }).join(), "1,2,3");
check("NaN", [3, 1, 2].sort(function () { return NaN; }).join(), "3,1,2");
check("toSorted", [3, 1, 2].toSorted(function (a, b) { return { valueOf: function () { return b - a; } }; }).join(), "3,2,1");

function throws(name, result, ctor) {
    try {
        [3, 1, 2].sort(function () { return result; });
        print("FAIL " + name + ": no throw");
    } catch (e) {
        check(name, e instanceof ctor, true);
    }
}
throws("valueOf throws", { valueOf: function () { throw new RangeError("v"); } }, RangeError);
throws("symbol", Symbol("s"), TypeError);
throws("bigint", 1n, TypeError);
throws("no primitive", { valueOf: function () { return {}; }, toString: function () { return {}; } }, TypeError);
print("done");
