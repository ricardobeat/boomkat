// Async functions that RETURN THROUGH A FINALLY block must settle their own
// Promise, not overwrite it with the raw return value.
//
// The ENDFINALLY pending-return completion path used to pop the activation and
// write the bare return value into callee_result, clobbering the Promise that
// vm_calls.c3 had pre-installed there.  `f().then(...)` then crashed with
// "undefined is not a function" — and under the test262 harness that crash
// degenerated into a MEMKILL, which is why it went unnoticed for so long.
//
// Every case below therefore calls .then() on the returned value: if the fix
// regresses, the callee returns a non-Promise and .then is not a function, so
// the test dies loudly instead of silently passing.
//
// Expectations verified against node v24, including the ordering assertions.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Deferred results are collected here and checked in a final microtask, in the
// same style as test/test_async.js.
var results = [];
function expect(tag, actual, want) {
    results.push([tag, actual === want, actual, want]);
}

// `pending` guards against the file exiting before the assertions run: it is
// incremented for every async case and decremented when that case reports.
// The summary refuses to pass if any case never reported.
var started = 0, reported = 0;

// Drive one async function and record its settled value (or rejection reason).
// `f()` MUST return a real Promise — calling .then on it is itself the
// regression check.
function check(tag, f, wantValue) {
    started++;
    var p = f();
    assert(p instanceof Promise, tag + ": call returns a Promise");
    assert(typeof p.then === "function", tag + ": result has .then");
    p.then(function (v) {
        reported++;
        expect(tag, v, wantValue);
    }, function (e) {
        reported++;
        expect(tag + " (unexpected rejection: " + e + ")", "rejected", wantValue);
    });
}

// Same, but the function is expected to REJECT with `wantReason`.
function checkReject(tag, f, wantReason) {
    started++;
    var p = f();
    assert(p instanceof Promise, tag + ": call returns a Promise");
    assert(typeof p.then === "function", tag + ": result has .then");
    p.then(function (v) {
        reported++;
        expect(tag + " (unexpectedly fulfilled with " + v + ")", "fulfilled", "rejected");
    }, function (e) {
        reported++;
        expect(tag, e, wantReason);
    });
}

// ---------------------------------------------------------------------------
// 1. The core case: finally's return overrides the try's return.
// ---------------------------------------------------------------------------
check("try-return finally-return", async function () {
    try { return 1; } finally { return 2; }
}, 2);

// try-throw / finally-return: the finally return swallows the exception.
check("try-throw finally-return", async function () {
    try { throw new Error("boom"); } finally { return 3; }
}, 3);

// try-reject (await a rejected promise) / finally-return.
check("try-reject finally-return", async function () {
    try { await Promise.reject("rej"); } finally { return 4; }
}, 4);

// finally-return after a normal (non-return) try completion.
check("try-normal finally-return", async function () {
    try { var x = 1; } finally { return 5; }
}, 5);

// A plain return through a finally that does NOT return: value survives.
check("try-return finally-plain", async function () {
    try { return 6; } finally { var side = 1; }
}, 6);

// ---------------------------------------------------------------------------
// 2. Returning a Promise through finally must ADOPT its settlement,
//    not fulfil with the promise object itself.
// ---------------------------------------------------------------------------
check("finally returns resolved Promise", async function () {
    try { return "ignored"; } finally { return Promise.resolve(7); }
}, 7);

checkReject("finally returns rejected Promise", async function () {
    try { return "ignored"; } finally { return Promise.reject("prej"); }
}, "prej");

// Adoption must be recursive-ish: a promise resolved with a promise.
check("finally returns Promise of Promise", async function () {
    try { return "ignored"; } finally { return Promise.resolve(Promise.resolve(8)); }
}, 8);

// A pending promise returned from finally, settled later.
var lateResolve;
var latePromise = new Promise(function (r) { lateResolve = r; });
check("finally returns pending Promise", async function () {
    try { return "ignored"; } finally { return latePromise; }
}, 9);
lateResolve(9);

// ---------------------------------------------------------------------------
// 3. Returning a THENABLE through finally must also be adopted.
// ---------------------------------------------------------------------------
check("finally returns thenable", async function () {
    try { return "ignored"; } finally {
        return { then: function (res) { res(10); } };
    }
}, 10);

checkReject("finally returns rejecting thenable", async function () {
    try { return "ignored"; } finally {
        return { then: function (res, rej) { rej("trej"); } };
    }
}, "trej");

// A thenable whose .then throws rejects the async function's promise.
checkReject("finally returns throwing thenable", async function () {
    try { return "ignored"; } finally {
        return { then: function () { throw "tthrow"; } };
    }
}, "tthrow");

// ---------------------------------------------------------------------------
// 4. await before the try, and await INSIDE the finally.
//    These force the resume path (builtin_async_resume re-entry), where the
//    activation completes with no live caller frame.
// ---------------------------------------------------------------------------
check("await before try, finally-return", async function () {
    var a = await Promise.resolve(10);
    try { return a; } finally { return a + 1; }
}, 11);

check("await inside finally, then return", async function () {
    try { return 0; } finally {
        var b = await Promise.resolve(12);
        return b;
    }
}, 12);

check("await inside try AND finally", async function () {
    try {
        var a = await Promise.resolve(1);
        return a;
    } finally {
        var b = await Promise.resolve(13);
        return b;
    }
}, 13);

check("await after throw, finally awaits then returns", async function () {
    try {
        await Promise.resolve(1);
        throw "inner";
    } finally {
        await Promise.resolve(1);
        return 14;
    }
}, 14);

// await on a rejected promise inside the finally, caught inside the finally.
check("finally catches its own await rejection", async function () {
    try { return 0; } finally {
        try { await Promise.reject("fr"); } catch (e) { return "caught " + e; }
    }
}, "caught fr");

// ---------------------------------------------------------------------------
// 5. Nested try/finally where the INNER returns.
// ---------------------------------------------------------------------------
check("inner finally returns, outer finally plain", async function () {
    try {
        try { return 1; } finally { return 15; }
    } finally { var s = 1; }
}, 15);

check("inner finally returns, outer finally returns", async function () {
    try {
        try { return 1; } finally { return 15; }
    } finally { return 16; }
}, 16);

check("inner try returns, outer finally returns", async function () {
    try {
        try { return 1; } finally { var s = 1; }
    } finally { return 17; }
}, 17);

check("three-deep nested finally returns", async function () {
    try {
        try {
            try { return 1; } finally { return 2; }
        } finally { return 3; }
    } finally { return 18; }
}, 18);

check("nested with awaits at every level", async function () {
    try {
        try {
            await Promise.resolve(1);
            return 1;
        } finally {
            await Promise.resolve(1);
            return 2;
        }
    } finally {
        await Promise.resolve(1);
        return 19;
    }
}, 19);

// try/catch/finally where catch returns and finally returns.
check("catch-return overridden by finally-return", async function () {
    try { throw "x"; } catch (e) { return 1; } finally { return 20; }
}, 20);

check("catch-return survives plain finally", async function () {
    try { throw "x"; } catch (e) { return 21; } finally { var s = 1; }
}, 21);

// ---------------------------------------------------------------------------
// 6. Rejection propagating OUT of a finally.
// ---------------------------------------------------------------------------
checkReject("finally throws over try-return", async function () {
    try { return 1; } finally { throw "fthrow"; }
}, "fthrow");

checkReject("finally throws over try-throw", async function () {
    try { throw "orig"; } finally { throw "fthrow2"; }
}, "fthrow2");

checkReject("finally awaits a rejection (uncaught)", async function () {
    try { return 1; } finally { await Promise.reject("fawait"); }
}, "fawait");

checkReject("try-return, finally throws after await", async function () {
    try { return 1; } finally {
        await Promise.resolve(1);
        throw "afterawait";
    }
}, "afterawait");

// An exception from the try survives a finally that neither returns nor throws.
checkReject("try-throw, plain finally", async function () {
    try { throw "survives"; } finally { var s = 1; }
}, "survives");

// ---------------------------------------------------------------------------
// 7. Async arrow functions, async methods, async generators.
// ---------------------------------------------------------------------------
check("async arrow, finally-return", async () => {
    try { return 1; } finally { return 22; }
}, 22);

check("async arrow, await + finally-return", async () => {
    await Promise.resolve(1);
    try { return 1; } finally { return 23; }
}, 23);

checkReject("async arrow, finally throws", async () => {
    try { return 1; } finally { throw "arrowthrow"; }
}, "arrowthrow");

var methodHolder = {
    async m() { try { return 1; } finally { return 24; } },
    async mAwait() { try { await Promise.resolve(1); return 1; } finally { return 25; } }
};
check("async method, finally-return", function () { return methodHolder.m(); }, 24);
check("async method with await, finally-return", function () { return methodHolder.mAwait(); }, 25);

class AsyncClass {
    async instanceM() { try { return 1; } finally { return 26; } }
    static async staticM() { try { return 1; } finally { return 27; } }
}
var inst = new AsyncClass();
check("async instance method, finally-return", function () { return inst.instanceM(); }, 26);
check("async static method, finally-return", function () { return AsyncClass.staticM(); }, 27);

// `this` must survive the finally-return path.
var thisHolder = {
    v: 28,
    async m() { try { return 0; } finally { return this.v; } }
};
check("async method finally-return reads this", function () { return thisHolder.m(); }, 28);

// NOTE: an async *generator* returning through a finally is deliberately NOT
// covered here. It behaves correctly in isolation --
//
//     async function* agen() { yield 1; try { return 2; } finally { return 29; } }
//
// yields {1,false} then {29,true}, matching node. But when driven from an async
// IIFE alongside the ~38 other async cases in this file, the generator's driving
// promise never settles at all (its own .then never fires, even after a
// 400-deep microtask drain). A *plain* `async function* g(){ yield 1; return 29; }`
// with no try/finally wedges identically in the same context, so this is a
// pre-existing async-generator scheduling bug unrelated to the finally-return
// fix -- not something this regression test should encode. See the report
// accompanying this commit.

// Async IIFE.
check("async IIFE, finally-return", function () {
    return (async function () { try { return 1; } finally { return 30; } })();
}, 30);

// ---------------------------------------------------------------------------
// 8. ORDERING: the finally body must run before the promise settles, and
//    the settlement must be a microtask (not synchronous).
// ---------------------------------------------------------------------------
var order = [];
started++;
(function () {
    async function ordered() {
        order.push("try");
        try { return "tryval"; } finally {
            order.push("finally");
            return "finallyval";
        }
    }
    order.push("before-call");
    var p = ordered();
    // The body up to the first await (there is none here) runs synchronously,
    // so "try" and "finally" are already recorded — but the .then callback is
    // NOT, because settlement is observed via a microtask.
    order.push("after-call");
    p.then(function (v) {
        order.push("then:" + v);
        reported++;
        results.push([
            "ordering (sync body, microtask then)",
            order.join(",") === "before-call,try,finally,after-call,then:finallyval",
            order.join(","),
            "before-call,try,finally,after-call,then:finallyval"
        ]);
    });
})();

// Ordering with an await inside the finally: everything after the await is
// deferred to a microtask, so "after-call" lands before "finally-after-await".
var order2 = [];
started++;
(function () {
    async function ordered2() {
        try {
            order2.push("try");
            return "tryval";
        } finally {
            order2.push("finally-before-await");
            await Promise.resolve();
            order2.push("finally-after-await");
            return "v2";
        }
    }
    order2.push("before-call");
    var p = ordered2();
    order2.push("after-call");
    p.then(function (v) {
        order2.push("then:" + v);
        reported++;
        var want = "before-call,try,finally-before-await,after-call,finally-after-await,then:v2";
        results.push([
            "ordering (await in finally)",
            order2.join(",") === want,
            order2.join(","),
            want
        ]);
    });
})();

// Interleaving: two async functions returning through finally settle in call
// order, proving neither clobbers the other's promise.
var interleave = [];
started++;
(function () {
    async function a() { try { return 0; } finally { return "a"; } }
    async function b() { try { return 0; } finally { return "b"; } }
    var pa = a(), pb = b();
    pa.then(function (v) { interleave.push(v); });
    pb.then(function (v) {
        interleave.push(v);
        reported++;
        results.push([
            "interleaved settlement order",
            interleave.join(",") === "a,b",
            interleave.join(","),
            "a,b"
        ]);
    });
})();

// ---------------------------------------------------------------------------
// 9. The returned promise is a distinct, chainable Promise.
// ---------------------------------------------------------------------------
started++;
(function () {
    async function f() { try { return 1; } finally { return 31; } }
    var p = f();
    // Chaining twice exercises the settled promise as a real Promise, which the
    // pre-fix engine (a raw number in callee_result) could not do at all.
    p.then(function (v) { return v + 1; })
     .then(function (v) {
         reported++;
         results.push(["chained then", v === 32, v, 32]);
     });
})();

// await-ing the result from another async function.
check("awaiting a finally-returning async fn", async function () {
    async function inner() { try { return 1; } finally { return 33; } }
    var v = await inner();
    return v;
}, 33);

// Promise.all over several finally-returning async functions.
started++;
(function () {
    async function mk(n) { try { return 0; } finally { return n; } }
    Promise.all([mk(1), mk(2), mk(3)]).then(function (vals) {
        reported++;
        results.push([
            "Promise.all over finally-returns",
            vals.join(",") === "1,2,3",
            vals.join(","),
            "1,2,3"
        ]);
    });
})();

// ---------------------------------------------------------------------------
// Final microtask: drain several levels so every deferred settlement (including
// pending-promise adoptions, which need extra hops) has reported, then verify
// that *all* started cases actually reported before summarising.
// ---------------------------------------------------------------------------
function drain(n, fn) {
    if (n === 0) { fn(); return; }
    Promise.resolve().then(function () { drain(n - 1, fn); });
}

drain(30, function () {
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
    print("async_finally_return: " + pass + " passed, " + fail + " failed");
    // NOTE: a throw from inside a microtask does not set a non-zero exit status
    // in this engine (verified: `Promise.resolve().then(()=>{throw x})` exits 0),
    // so automation must key off stdout. "SOME TESTS FAILED" is the same marker
    // test/forin.js uses. The throw is kept for parity with test/test_async.js
    // and so the failure is loud when run under node.
    if (fail > 0) {
        print("SOME TESTS FAILED");
        throw new Error("FAIL");
    }
});
