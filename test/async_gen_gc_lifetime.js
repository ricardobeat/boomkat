// GC lifetime of async-generator state and the async-resume wrapper.
//
// Three distinct object-lifetime bugs are covered here. All three are GC
// timing bugs: they need enough live objects for a collection to land in the
// exact window, which is why the promise chains below are deliberately long
// (the GC trigger scales with the live-object count, so a ~100-deep chain is
// what first makes a collection fall inside the async machinery).
//
//  1. DOUBLE FREE of a GeneratorState. An async generator's state was freed by
//     its GENERATOR instance, while the reaction closures sharing that state
//     decided ownership by READING gs.is_async_gen — from the struct the same
//     single-pass sweep had already freed. The recycled read said "not an async
//     generator", so a sibling freed it a second time. Symptom: SIGTRAP /
//     "pointer being freed was not allocated".
//
//  2. UNROOTED IN-FLIGHT REQUEST. Once dequeued, an async-generator request's
//     promise lived only in a C3 local, invisible to the mark phase, so the
//     next allocation could sweep the very promise the drain was about to
//     settle. Its slot was then recycled into a new promise, and the chain read
//     back an unrelated value. Symptom: `Promise.resolve(0)` observed as
//     `[object Object]`, so `v+1` string-concatenated down the chain.
//
//  3. SWEPT ASYNC-RESUME WRAPPER. The callable used to re-enter a suspended
//     async body was a fresh object held only by its temproot, and the resume
//     path drops native_frame_depth to 0 right before the call — which is
//     exactly what re-enables temproot clearing. A safepoint GC inside the call
//     swept the object being called through. Latent without ASAN.
//
// Every assertion below runs inside a microtask. A throw there exits 0 in this
// engine, so failures are reported via the stdout marker instead.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var pending = 0, finished = 0;
function track() { pending++; }
function settle() { finished++; }

// Build an `n`-deep chain of `v => v+1` starting from 0; resolves to n.
function chain(n) {
    var p = Promise.resolve(0);
    for (var i = 0; i < n; i++) p = p.then(function (v) { return v + 1; });
    return p;
}

// --- 1 + 2: async generator alongside a long promise chain -----------------
// The generator makes a collection land inside the async-generator machinery;
// the chain depth decides whether that collection happens at all. Depths span
// the pre-fix boundary (~90 passed, >=95 crashed, >=128 corrupted).
[10, 90, 100, 128, 200, 400, 1000].forEach(function (depth) {
    track();
    async function* g() { yield 1; }
    // g() is dropped immediately: nothing in JS references the instance, so it
    // survives only if the engine roots its in-flight work.
    g().next();
    chain(depth).then(function (v) {
        assert(typeof v === "number", "depth " + depth + ": typeof is " + (typeof v) + ", want number");
        assert(v === depth, "depth " + depth + ": got " + v);
        settle();
    });
});

// The same shape with the generator awaited, which is how the original report
// reproduced it.
[100, 400].forEach(function (depth) {
    track();
    async function* g() { yield 1; }
    (async function () { await g().next(); })();
    chain(depth).then(function (v) {
        assert(v === depth, "awaited-gen depth " + depth + ": got " + v);
        settle();
    });
});

// --- 2: abandoned and partially-drained generators -------------------------
// A generator abandoned mid-iteration must not corrupt later chain values, and
// must not keep itself alive forever either.
track();
(function () {
    async function* g() { for (var i = 0; i < 50; i++) yield i; }
    for (var i = 0; i < 40; i++) { var it = g(); it.next(); it.next(); }
    chain(600).then(function (v) {
        assert(v === 600, "abandoned generators: chain got " + v);
        settle();
    });
})();

// --- 2: many concurrent for-await consumers over a long chain --------------
track();
(function () {
    async function* g() { for (var i = 0; i < 50; i++) yield i; }
    var bad = 0, done = 0, want = 20;
    for (var j = 0; j < want; j++) {
        (async function () {
            var s = 0;
            for await (var v of g()) s += v;
            if (s !== 1225) bad++;
            done++;
        })();
    }
    chain(800).then(function (v) {
        assert(v === 800, "concurrent for-await: chain got " + v);
        assert(bad === 0, "concurrent for-await: " + bad + " wrong sums");
        assert(done === want, "concurrent for-await: " + done + "/" + want + " finished");
        settle();
    });
})();

// --- 2: .return() / .throw() on a suspended async generator ----------------
track();
(function () {
    async function* g() { for (var i = 0; i < 10; i++) yield i; }
    var checks = 0;
    (async function () {
        var it = g();
        await it.next();
        var r = await it.return(42);
        assert(r.done === true && r.value === 42, "return() on suspended generator");
        checks++;

        var it2 = g();
        await it2.next();
        try {
            await it2.throw(new Error("injected"));
            assert(false, "throw() on suspended generator should reject");
        } catch (e) {
            assert(true, "throw() rejected");
        }
        checks++;

        assert(checks === 2, "return/throw: only " + checks + " checks ran");
        settle();
    })();
})();

// --- 3: repeated await resumes with allocation churn between them ----------
// Each `await` re-enters through the resume wrapper; the object churn gives a
// safepoint GC every opportunity to land inside that call.
track();
(async function () {
    var wrong = 0;
    for (var k = 0; k < 40; k++) {
        var v = await chain(200);
        if (v !== 200) wrong++;
        var junk = [];
        for (var i = 0; i < 200; i++) junk.push({ a: i, b: "s" + i, c: [i] });
    }
    assert(wrong === 0, "await-resume churn: " + wrong + " wrong values");
    settle();
})();

// --- 3: rejection resumes take the same wrapper path ------------------------
track();
(async function () {
    var caught = 0;
    for (var k = 0; k < 30; k++) {
        try {
            await chain(100).then(function () { throw new Error("boom"); });
        } catch (e) {
            caught++;
        }
        var junk = [];
        for (var i = 0; i < 200; i++) junk.push({ x: i });
    }
    assert(caught === 30, "reject-resume churn: caught " + caught + "/30");
    settle();
})();

// --- Final report ----------------------------------------------------------
// Every group calls settle() exactly once. Poll on the microtask queue until
// all of them have, rather than racing a fixed-length chain: the groups above
// take wildly different numbers of turns, and a chain long enough to outlast
// them today would be a silent no-op if one of them regressed into never
// settling. The cap turns "a group stopped firing" into a loud failure.
var polls = 0;
function report() {
    if (finished < pending && polls++ < 200000) {
        Promise.resolve().then(report);
        return;
    }
    assert(finished === pending, "only " + finished + "/" + pending + " groups settled");
    print("pass " + pass + " / fail " + fail);
    if (fail > 0) {
        print("SOME TESTS FAILED");
        throw new Error("FAIL");
    }
}
report();
