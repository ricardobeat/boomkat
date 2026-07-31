// Async-generator request queue keeps draining after a settle.
//
// GeneratorState carried one field, ag_current_request, doing two jobs at once:
// a GC root for the promise of the request being serviced, and the flag
// async_gen_drain reads to decide whether a body resume is already outstanding.
// Those roles need opposite lifetimes. As a root the promise must stay marked
// *through* the settle, which allocates an IteratorResult and runs the
// promise's reactions. As a guard it must be released *before* that settle,
// because a reaction may enqueue another request and re-enter the drain.
//
// The early-exit settle paths never cleared the field, so the re-entering drain
// saw a stale in-flight marker, returned without servicing anything, and the
// outer loop moved on to a queue nothing would ever come back for. Every later
// next/return/throw returned a forever-pending promise. Splitting the field
// into ag_root_promise (root) and ag_body_in_flight (guard), with both
// lifetimes owned by the two settle helpers, removes the whole class.
//
// test262 covers only .throw() at SUSPENDED_YIELD and two SUSPENDED_START
// cases; shapes C and D below have no upstream coverage at all, so this file is
// the only thing holding that line.
//
// Assertions run inside microtasks, where a throw exits 0 in this engine, so
// results are reported via a stdout marker. The report polls until every group
// settles rather than waiting a fixed number of turns: a wedged generator
// leaves its promise pending forever, and a fixed-length chain would grade that
// as a silent pass — exactly the failure this file exists to catch.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

var pending = 0, finished = 0;
function track() { pending++; }
function settle() { finished++; }

// --- A: .throw() at SUSPENDED_YIELD, caught by the body --------------------
// The generator survives the throw and yields again. This path always worked;
// it is here so a fix to the wedging cases cannot quietly break it.
track();
(function () {
    async function* g() {
        try { yield 1; } catch (e) { assert(e === "boom", "A: caught " + e); }
        yield 2;
    }
    var it = g();
    var seen = [];
    it.next().then(function (r) { seen.push(r.value); });
    it.throw("boom").then(function (r) { seen.push(r.value); });
    it.next().then(function (r) {
        seen.push(r.done);
        assert(seen.join(",") === "1,2,true", "A: sequence " + seen.join(","));
        settle();
    });
})();

// --- B: .throw() on a COMPLETED generator ----------------------------------
// The rejection is a COMPLETED-state fast answer, which settles without any
// body resume. The queued next() behind it must still be serviced.
track();
(function () {
    async function* g() { yield 1; }
    var it = g();
    it.next();
    it.next();
    it.throw(new Error("x")).then(
        function () { assert(false, "B: throw should reject"); },
        function (e) { assert(e.message === "x", "B: reason " + e.message); });
    it.next().then(function (r) {
        assert(r.done === true && r.value === undefined, "B: tail next " + r.value + "/" + r.done);
        settle();
    });
})();

// --- C: two .throw()s queued at SUSPENDED_START ----------------------------
// The first throw completes the generator without running body code, settling
// from an early-exit path. Before the split, the second throw and everything
// behind it never settled.
track();
(function () {
    async function* g() { yield 1; }
    var it = g();
    var seen = [];
    it.throw("e1").then(null, function (e) { seen.push(e); });
    it.throw("e2").then(null, function (e) { seen.push(e); });
    it.next().then(function (r) {
        seen.push(r.done);
        assert(seen.join(",") === "e1,e2,true", "C: sequence " + seen.join(","));
        settle();
    });
})();

// --- D: .throw() at SUSPENDED_START then .return() -------------------------
// Same early-exit settle as C, but the request behind it is a return, which
// awaits its value before settling {value, done:true}.
track();
(function () {
    async function* g() { yield 1; }
    var it = g();
    var seen = [];
    it.throw("e1").then(null, function (e) { seen.push(e); });
    it.return(9).then(function (r) { seen.push(r.value + "/" + r.done); });
    it.next().then(function (r) {
        seen.push(r.value + "/" + r.done);
        assert(seen.join(",") === "e1,9/true,undefined/true", "D: sequence " + seen.join(","));
        settle();
    });
})();

// --- E: a reaction queues a new request from inside the settle -------------
// The re-entrancy the guard exists for. The rejection handler calls next() on
// the same generator while the drain is still on the stack, so the re-entering
// drain must see an idle generator.
track();
(function () {
    async function* g() { yield 1; }
    var it = g();
    it.throw("e1").then(null, function () {
        it.next().then(function (r) {
            assert(r.done === true, "E: re-entrant next " + r.done);
            settle();
        });
    });
})();

// --- F: the body awaits between yields -------------------------------------
// Exercises the in-flight guard doing its real job: the body suspends on an
// internal await, so the queued requests must wait for the await reaction
// rather than starting a second resume.
track();
(function () {
    async function* g() {
        yield 1;
        await Promise.resolve();
        yield 2;
        await Promise.resolve();
        throw "late";
    }
    var it = g();
    var seen = [];
    it.next().then(function (r) { seen.push(r.value); });
    it.next().then(function (r) { seen.push(r.value); });
    it.next().then(null, function (e) { seen.push(e); });
    it.next().then(function (r) {
        seen.push(r.done);
        assert(seen.join(",") === "1,2,late,true", "F: sequence " + seen.join(","));
        settle();
    });
})();

// --- Final report ----------------------------------------------------------
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
