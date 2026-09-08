// A Proxy "has" trap that throws makes proxy_mop_has return false, which is
// indistinguishable from "not present" at the call site. Array.prototype
// methods that only tested ctx.should_throw after arr_has_prop silently
// swallowed the trap's exception and treated every index as a hole --
// forEach/map/filter/every/some/reduce/reduceRight/concat/reverse/slice/
// splice/flat/flatMap all completed normally instead of propagating it.
// reduce/reduceRight with no initial value were worse: the accumulator search
// walked off the end and threw a spurious "Reduce of empty array with no
// initial value" TypeError that masked the real error.

var failures = 0;
function check(name, actual, expected) {
    if (actual !== expected) {
        print("FAIL: " + name + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Every method must propagate the trap's own Error, not swallow it and not
// replace it with an error of its own.
function throwingProxy() {
    return new Proxy([1, 2, 3], {
        has: function () { throw new Error("bang"); },
    });
}

function propagates(name, fn) {
    var message = "no throw";
    try {
        fn(throwingProxy());
    } catch (e) {
        message = e.message;
    }
    check(name + " propagates the has trap's throw", message, "bang");
}

propagates("forEach",            function (p) { p.forEach(function () {}); });
propagates("map",                function (p) { p.map(function (x) { return x; }); });
propagates("filter",             function (p) { p.filter(function () { return true; }); });
propagates("every",              function (p) { p.every(function () { return true; }); });
propagates("some",               function (p) { p.some(function () { return false; }); });
propagates("reduce",             function (p) { p.reduce(function (a, b) { return a + b; }, 0); });
propagates("reduceRight",        function (p) { p.reduceRight(function (a, b) { return a + b; }, 0); });
propagates("concat",             function (p) { [].concat(p); });
propagates("reverse",            function (p) { p.reverse(); });
propagates("slice",              function (p) { p.slice(0); });
propagates("splice",             function (p) { p.splice(0, 2); });
propagates("flat",               function (p) { p.flat(); });
propagates("flatMap",            function (p) { p.flatMap(function (x) { return x; }); });
propagates("shift",              function (p) { p.shift(); });
propagates("sort",               function (p) { p.sort(); });
propagates("copyWithin",         function (p) { p.copyWithin(0, 1); });

// With no initial value the accumulator search must abort on the throw rather
// than run off the end and report the array as empty.
propagates("reduce with no initial value",      function (p) { p.reduce(function (a, b) { return a + b; }); });
propagates("reduceRight with no initial value", function (p) { p.reduceRight(function (a, b) { return a + b; }); });

// A non-throwing trap still reports presence normally.
{
    var seen = [];
    var quiet = new Proxy([1, 2, 3], {
        has: function (t, pk) { return pk in t; },
    });
    quiet.forEach(function (x) { seen.push(x); });
    check("a non-throwing has trap still iterates", seen.join(","), "1,2,3");
}

if (failures > 0) {
    throw new Error(failures + " check(s) failed");
}
print("OK");
