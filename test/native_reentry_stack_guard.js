// Recursion that bounces through a native builtin must throw a catchable
// RangeError instead of faulting the native stack, and the engine must stay
// usable afterwards. Each vector re-enters the VM through vm_call_fn_impl,
// which resets activation_count, so MAX_CALLS never bounds it.
//
// Before the run-depth guard these segfaulted. The sort vector in particular
// kept faulting after the guard existed, because Array.prototype.sort carried
// two 64 Kb stack buffers and exhausted the stack below the guard's limit.

var failures = 0;
function check(name, got, want) {
    if (got !== want) {
        print("FAIL " + name + ": got " + got + ", want " + want);
        failures++;
    }
}

function rangeErrorFrom(fn) {
    try {
        fn();
        return "no-throw";
    } catch (e) {
        return e instanceof RangeError ? "RangeError" : ("other:" + e);
    }
}

check("proxy get trap", rangeErrorFrom(function () {
    var o = new Proxy({}, { get: function (t, p) { return o[p]; } });
    return o.x;
}), "RangeError");

check("sort comparator", rangeErrorFrom(function () {
    var a = [3, 1, 2];
    function cmp(x, y) { a.sort(cmp); return x - y; }
    a.sort(cmp);
}), "RangeError");

check("map callback", rangeErrorFrom(function () {
    var a = [1];
    function f() { return a.map(f); }
    return a.map(f);
}), "RangeError");

check("Symbol.toPrimitive", rangeErrorFrom(function () {
    var o = {};
    o[Symbol.toPrimitive] = function () { return "" + o; };
    return "" + o;
}), "RangeError");

check("accessor recursion", rangeErrorFrom(function () {
    var o = {};
    Object.defineProperty(o, "x", { get: function () { return o.x; } });
    return o.x;
}), "RangeError");

// The RangeError travels on the has_error channel only. If it also set
// throw_pending it would survive the unwind and re-fire here, after the
// catch above already handled it.
var acc = 0;
for (var i = 0; i < 1000; i++) { acc += i; }
check("arithmetic after recovery", acc, 499500);
check("sort after recovery", [3, 1, 2].sort(function (a, b) { return a - b; }).join(","), "1,2,3");
check("map after recovery", [1, 2, 3].map(function (v) { return v * 2; }).join(","), "2,4,6");

// Legitimate recursion through the same builtins must still complete.
function nestedProxy(depth) {
    var o = new Proxy({}, {
        get: function (t, p) { return depth === 0 ? depth : nestedProxy(depth - 1)[p]; }
    });
    return o;
}
check("nested proxy depth 20", nestedProxy(20).v, 0);

function nestedSort(depth) {
    var a = [2, 1];
    a.sort(function (x, y) {
        if (depth > 0) { nestedSort(depth - 1); }
        return x - y;
    });
    return a.join(",");
}
check("nested sort depth 20", nestedSort(20), "1,2");

// Sizes either side of the sort inline-buffer boundary, since sort now spills
// to the temp allocator instead of reserving a fixed 4096-element frame.
function sortedRun(n) {
    var a = [];
    for (var i = 0; i < n; i++) { a.push((i * 7919) % n); }
    a.sort(function (x, y) { return x - y; });
    for (var j = 1; j < a.length; j++) { if (a[j - 1] > a[j]) return "unsorted"; }
    return a.length;
}
var sizes = [0, 1, 63, 64, 65, 1000];
for (var s = 0; s < sizes.length; s++) {
    check("sort size " + sizes[s], sortedRun(sizes[s]), sizes[s]);
}

// A proxy on the super base's prototype chain receives `this` as the trap
// receiver, matching PUTPROP_SUPER. GETPROP_SUPER used to do an ordinary
// lookup and hand the trap the holder instead.
var superReceiverOk = false;
(function () {
    class base { constructor() { } }
    class mid extends new Proxy(base, {}) {
        constructor() { super(); }
        read() { return super.prop; }
    }
    var inst = new mid();
    Object.setPrototypeOf(base.prototype, new Proxy(Object.prototype, {
        get: function (target, p, receiver) {
            superReceiverOk = receiver === inst;
            return "found";
        }
    }));
    check("super.prop through proxy", inst.read(), "found");
})();
check("super.prop trap receiver", superReceiverOk, true);

if (failures === 0) {
    print("native_reentry_stack_guard: all checks passed");
} else {
    print("FAIL native_reentry_stack_guard: " + failures + " check(s) failed");
}
