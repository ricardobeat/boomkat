// B18 (plan 070): async callbacks invoked by builtins must return promises.
// The builtin callback path (vm_call_fn_impl) ran async bodies synchronously
// to completion and handed back the raw return value, so
// `[1,2].map(async x => x)` gave `[1,2]` instead of `[Promise, Promise]`,
// `filter(async () => false)` dropped every element, and any callback that
// actually suspends (`await`) lost its value entirely (`[undefined, undefined]`).
var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

function isPromise(v) { return v !== null && typeof v === "object" && v instanceof Promise; }

async function run() {
    // map: non-suspending async callback returns promises, resolving to the values
    var a = [1, 2, 3].map(async function(x) { return x * 2; });
    assert(a instanceof Array, "map returns array");
    assert(isPromise(a[0]) && isPromise(a[2]), "map stores promises");
    assert((await Promise.all(a)).join(",") === "2,4,6", "map promises resolve");

    // map: suspending async callback (the shape that resolved to undefined)
    var b = [1, 2].map(async function(x) { await null; return x * 10; });
    assert(isPromise(b[0]), "suspending callback still returns promise");
    assert((await Promise.all(b)).join(",") === "10,20", "suspending callbacks resolve");

    // filter: a promise is always truthy, so an async predicate keeps every element
    assert((await [1, 2, 3].filter(async function() { return false; })).length === 3,
           "filter with async false predicate keeps all");
    assert((await [1, 2].filter(async function() { return true; })).length === 2,
           "filter with async true predicate keeps all");

    // some / every with async predicates
    assert(await [1, 2].some(async function(x) { return x === 2; }), "some with async predicate");
    assert(await [1, 2].every(async function(x) { return x > 0; }), "every with async predicate");

    // forEach with suspending async body: side effects land after the microtask drain
    var acc = [];
    await new Promise(function(res) {
        [1, 2].forEach(async function(x) { await 0; acc.push(x); });
        res();
    });
    assert(acc.join(",") === "1,2", "forEach async callbacks run");

    // Promise executor receives an async function: its promise settles the outer
    var p = new Promise(async function(resolve) { await 0; resolve(42); });
    assert(await p === 42, "async Promise executor");

    // throwing async callback: the stored promise rejects, Promise.all propagates
    var c = [1].map(async function() { throw new Error("boom"); });
    var threw = false;
    try { await Promise.all(c); } catch (e) { threw = e.message === "boom"; }
    assert(threw, "throwing async callback rejects its promise");

    // .then with a suspending async handler adopts the returned promise
    assert(await Promise.resolve(1).then(async function(x) { await null; return x + 1; }) === 2,
           ".then adopts suspending async handler result");

    // plain function returning a promise (pre-existing behavior, must stay intact)
    var d = [1].map(function(x) { return Promise.resolve(x * 100); });
    assert((await Promise.all(d))[0] === 100, "plain fn returning promise");

    print("test_async_builtin_callbacks: " + pass + " passed, " + fail + " failed");
    if (fail > 0) throw new Error("FAIL");
}
run().catch(function(e) { print("UNCAUGHT: " + e.message); throw e; });
