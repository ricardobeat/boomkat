// ES2015 §27.2.3.1 step 9: when the executor passed to `new Promise` throws,
// the constructor rejects the promise and returns it. The throw must not also
// propagate out of the constructor.
//
// Regression: heap.call_fn raises a callee's throw on three channels
// (heap.has_error, vm.has_error, vm.throw_pending). The constructor cleared
// only heap.has_error, so vm.has_error survived and the next opcode to check
// it re-fired the exception. The promise was correctly rejected *and* the
// throw escaped, so the statement after `new Promise` never ran.

function check(name, cond) {
    print((cond ? "ok   " : "FAIL ") + name);
}

// 1. The constructor returns normally; the statement after it runs.
var reached = false;
var p1 = new Promise(function (resolve) { throw new TypeError("t1"); });
reached = true;
check("constructor returned instead of throwing", reached);
check("constructor returned a Promise", p1 instanceof Promise);

// 2. The promise is rejected with the thrown value.
var rejected = null;
p1.then(null, function (e) { rejected = e; });

// 3. The throw does not resurface at a later, unrelated operation. Before the
//    fix this line was where the stale channel re-fired.
var probe = "" + (p1 instanceof Promise);
check("no stale throw at the next operation", probe === "true");

// 4. Same shape inside a function, and through a subclass.
function inFunction() {
    var q = new Promise(function (resolve) { throw new TypeError("t2"); });
    q.then(null, function () {});
    return "returned";
}
var fnResult = "threw";
try { fnResult = inFunction(); } catch (e) { fnResult = "threw"; }
check("no propagation from inside a function", fnResult === "returned");

// A subclass constructor takes the Construct(C, [executor]) path and must not
// propagate either. The executor resolves before throwing, so the promise
// settles fulfilled and the throw is swallowed per step 9 — this avoids a
// separate, pre-existing bug where a *rejected* subclass promise is reported
// as an unhandled rejection even with a handler attached, which would make
// this file exit non-zero for an unrelated reason.
class MyPromise extends Promise {}
var subResult = "threw";
try {
    new MyPromise(function (resolve) { resolve(1); throw new TypeError("t3"); });
    subResult = "returned";
} catch (e) { subResult = "threw"; }
check("no propagation from a subclass constructor", subResult === "returned");

// 5. An executor that throws after calling resolve() still does not propagate:
//    the promise is already resolved, and the throw is swallowed per step 9.
var settled = "none";
var p2 = new Promise(function (resolve) { resolve(1); throw new TypeError("late"); });
p2.then(function (v) { settled = "fulfilled:" + v; }, function () { settled = "rejected"; });

// 6. The rejection is delivered on the microtask queue, once.
var rejectCount = 0;
var p3 = new Promise(function (resolve) { throw new TypeError("t4"); });
p3.then(null, function () { rejectCount++; });

Promise.resolve().then(function () {}).then(function () {}).then(function () {
    check("rejected with the thrown TypeError", rejected instanceof TypeError);
    check("rejection reason message preserved", rejected && rejected.message === "t1");
    check("resolve() before a throw wins", settled === "fulfilled:1");
    check("rejection handler ran exactly once", rejectCount === 1);
    print("=== DONE ===");
});
