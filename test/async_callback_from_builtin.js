// An async function invoked as a callback BY A BUILTIN must evaluate to a
// Promise, exactly as it does when invoked by the CALL opcode.
//
// Builtins reach a JS callback through vm_call_fn_impl (vm_execute.c3) rather
// than through CALL (vm_calls.c3).  That path handled RESUMING an async
// function but had no setup for an INITIAL async call, so it ran the body
// synchronously and handed back the raw return value:
//
//     [1, 2].map(async x => x)[0]     // was 1,  must be a Promise
//     [1, 2].filter(async () => false) // was [], must be [1, 2] --
//                                      // a Promise is always truthy
//
// The suspending shape is the sharper case and is covered below: an `await` in
// the callback pops the only activation on that path, halting the inner run
// with undefined.  The Promise must still come back, to be settled later when
// the microtask queue drains and the body resumes.  A fix that only installs
// the Promise for non-suspending callbacks turns this into a silent wrong
// answer (the elements resolve to null), which is worse than the original bug,
// so `await null` appears in most cases here on purpose.
//
// Expectations verified against node v24, ordering assertions included.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Deferred results are collected here and checked in a final microtask, in the
// same style as test/async_finally_return.js.
var results = [];
function expect(tag, actual, want) {
    results.push([tag, actual === want, actual, want]);
}

// `started`/`reported` guard against the file exiting before the assertions
// run: a throw from inside a microtask does not set a non-zero exit status, so
// a case that never reports would otherwise look like a pass.
var started = 0, reported = 0;

// Settle one Promise produced by a builtin-invoked async callback and record
// its value. `p` MUST be a real Promise -- calling .then on it is itself the
// regression check.
function settle(tag, p, wantValue) {
    started++;
    assert(p instanceof Promise, tag + ": callback result is a Promise");
    assert(typeof p.then === "function", tag + ": result has .then");
    p.then(function (v) {
        reported++;
        expect(tag, JSON.stringify(v), JSON.stringify(wantValue));
    }, function (e) {
        reported++;
        expect(tag, "rejected:" + e, "<fulfilled>");
    });
}

// --- map: non-suspending async callback ------------------------------------
// The body has no `await`, so it runs straight to RET. RET resolves the
// Promise; the element must still be the Promise, never the raw value.
var mapPlain = [1, 2].map(async function (x) { return x * 10; });
assert(mapPlain[0] instanceof Promise, "map/non-suspending: element 0 is a Promise");
assert(mapPlain[1] instanceof Promise, "map/non-suspending: element 1 is a Promise");
settle("map/non-suspending", Promise.all(mapPlain), [10, 20]);

// --- map: SUSPENDING async callback ----------------------------------------
// `await null` suspends the callback. The element must be a pending Promise
// that resolves to the eventual return value, not undefined and not null.
var mapAwait = [1, 2].map(async function (x) { await null; return x * 10; });
assert(mapAwait[0] instanceof Promise, "map/suspending: element 0 is a Promise");
settle("map/suspending", Promise.all(mapAwait), [10, 20]);

// Several awaits in one callback: each costs a microtask tick, and the
// activation is popped and restored once per tick.
var mapAwait3 = [1, 2, 3].map(async function (x) {
    await null; await null; await null;
    return x + 1;
});
settle("map/three-awaits", Promise.all(mapAwait3), [2, 3, 4]);

// Awaiting a genuinely pending Promise (resolved from a later microtask),
// rather than the already-settled `null` fast shape.
var deferred = new Promise(function (res) {
    Promise.resolve().then(function () { res(99); });
});
var mapPending = [1].map(async function (x) { return (await deferred) + x; });
settle("map/await-pending", Promise.all(mapPending), [100]);

// --- filter: async predicate keeps every element ---------------------------
// The predicate returns a Promise, and every Promise is truthy, so `false` and
// an awaited `false` both keep the element. This is the shape that silently
// dropped every element before the fix.
var filtFalse = [1, 2].filter(async function () { return false; });
assert(filtFalse.length === 2, "filter/non-suspending: keeps all elements, got " + filtFalse.length);
assert(filtFalse[0] === 1 && filtFalse[1] === 2, "filter/non-suspending: elements unchanged");

var filtAwait = [1, 2, 3].filter(async function () { await null; return false; });
assert(filtAwait.length === 3, "filter/suspending: keeps all elements, got " + filtAwait.length);
assert(filtAwait[2] === 3, "filter/suspending: elements unchanged");

// `some` short-circuits on the first truthy result, and a Promise is truthy,
// so it must stop after one call.
var someCalls = 0;
var someRes = [1, 2, 3].some(async function () { someCalls++; return false; });
assert(someRes === true, "some: a Promise is truthy so some() is true");
assert(someCalls === 1, "some: short-circuits after one call, got " + someCalls);

// `every` is the mirror image: truthy every time, so it visits all and is true.
var everyCalls = 0;
var everyRes = [1, 2, 3].every(async function () { everyCalls++; await null; return false; });
assert(everyRes === true, "every: all results truthy so every() is true");
assert(everyCalls === 3, "every: visits every element, got " + everyCalls);

// --- forEach ---------------------------------------------------------------
// forEach discards the returned Promise, so the visible effect is that the
// side effects still land, in order, after the awaits resolve.
var order = [];
[1, 2, 3].forEach(async function (x) { await null; order.push(x); });
assert(order.length === 0, "forEach: suspending callbacks have not run their tail yet");

// --- sort comparator -------------------------------------------------------
// An async comparator returns a Promise. ToNumber(Promise) is NaN, which sorts
// as 0 ("leave the order alone"), so the array comes back in its original
// order. The comparator must not throw and must not corrupt the array.
var sorted = [3, 1, 2].sort(async function (a, b) { return a - b; });
assert(sorted.length === 3, "sort: length preserved");
assert(JSON.stringify(sorted) === "[3,1,2]",
    "sort: async comparator leaves order untouched, got " + JSON.stringify(sorted));

var sortedAwait = [5, 4].sort(async function (a, b) { await null; return a - b; });
assert(JSON.stringify(sortedAwait) === "[5,4]",
    "sort/suspending: order untouched, got " + JSON.stringify(sortedAwait));

// --- rejection paths -------------------------------------------------------
// A throw after an await must reject the callback's Promise, not escape
// synchronously into the builtin.
var rejAfter = [1].map(async function () { await null; throw new Error("after-await"); });
started++;
assert(rejAfter[0] instanceof Promise, "reject/after-await: result is a Promise");
rejAfter[0].then(function () {
    reported++;
    expect("reject/after-await", "fulfilled", "rejected");
}, function (e) {
    reported++;
    expect("reject/after-await", e.message, "after-await");
});

// A throw BEFORE any await must also reject rather than propagate: an async
// function never throws synchronously.
var threw = false;
var rejBefore;
try {
    rejBefore = [1].map(async function () { throw new Error("before-await"); });
} catch (e) {
    threw = true;
}
assert(!threw, "reject/before-await: does not throw synchronously out of map");
started++;
assert(rejBefore[0] instanceof Promise, "reject/before-await: result is a Promise");
rejBefore[0].then(function () {
    reported++;
    expect("reject/before-await", "fulfilled", "rejected");
}, function (e) {
    reported++;
    expect("reject/before-await", e.message, "before-await");
});

// --- nesting ---------------------------------------------------------------
// An async callback that itself drives a builtin with async callbacks, so the
// call_fn path is re-entered while an outer async frame is suspended.
var nested = [1].map(async function (x) {
    var inner = [10, 20].map(async function (y) { await null; return y + x; });
    return await Promise.all(inner);
});
settle("nested", Promise.all(nested), [[11, 21]]);

// --- other builtins that invoke a callback ---------------------------------
settle("reduce", [1, 2, 3].reduce(async function (acc, x) {
    return (await acc) + x;
}, Promise.resolve(0)), 6);

var found = [1, 2, 3].find(async function () { await null; return false; });
assert(found === 1, "find: first element wins since every Promise is truthy, got " + found);

// A .then reaction is itself a builtin-invoked callback.
settle("then-reaction", Promise.resolve(1).then(async function (v) {
    await null;
    return v + 1;
}), 2);

// --- volume ----------------------------------------------------------------
// Many suspended callbacks at once: each holds a GeneratorState and a Promise
// across the microtask boundary, so a lifetime bug here shows up as a wrong
// value or a crash rather than as a leak.
var many = [];
for (var i = 0; i < 200; i++) { many.push(i); }
started++;
Promise.all(many.map(async function (x) { await null; return x + 1; })).then(function (v) {
    reported++;
    var ok = v.length === 200 && v[0] === 1 && v[199] === 200;
    expect("volume", ok ? "ok" : "len=" + v.length + " first=" + v[0] + " last=" + v[199], "ok");
});

// ---------------------------------------------------------------------------
function drain(n, fn) {
    if (n === 0) { fn(); return; }
    Promise.resolve().then(function () { drain(n - 1, fn); });
}

drain(40, function () {
    assert(JSON.stringify(order) === "[1,2,3]",
        "forEach: side effects landed in order, got " + JSON.stringify(order));
    assert(started > 0, "some async cases were started");
    assert(reported === started,
        "every async case reported (" + reported + "/" + started + ") -- "
        + "a shortfall means the file exited before its assertions ran");
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        if (r[1]) { pass++; }
        else {
            fail++;
            print("FAIL: " + r[0] + " -- expected [" + r[3] + "] got [" + r[2] + "]");
        }
    }
    print("async_callback_from_builtin: " + pass + " passed, " + fail + " failed");
    // A throw from inside a microtask does not set a non-zero exit status in
    // this engine, so automation keys off stdout; "SOME TESTS FAILED" is the
    // marker test/forin.js uses. The throw keeps the failure loud under node.
    if (fail > 0) {
        print("SOME TESTS FAILED");
        throw new Error("FAIL");
    }
});
