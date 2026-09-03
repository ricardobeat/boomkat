// A generator that delegates with `yield*` to a fresh instance of its OWN
// function (`function* g(n) { return yield* g(n - 1); }`) exercised two
// resume-path bugs, both stemming from heap.resume_gen being matched on
// compiled-function identity alone.
//
// 1. vm/vm_calls.c3's CALL resume path treated the body's own `g(n - 1)` call
//    as a resume of the running generator instead of the construction of a new
//    instance, so the generator resumed into itself until MAX_CALLS and threw
//    "Maximum call stack size exceeded" on the very first .next().
//
// 2. vm_call_fn_impl's resume path (vm/vm_execute.c3) never set
//    gs.state = GEN_EXECUTING the way dispatch_calls does, so a delegating
//    generator stayed GEN_SUSPENDED_* while its body ran. Each level of the
//    yield* chain then drove the innermost iterator an extra next(), and
//    depth >= 2 silently dropped yielded values (g(2) reported 2 first,
//    skipping 1) rather than crashing.
//
// Expected values are node's (runs unmodified under node with `--import` a
// shim defining print()).

var failures = 0;
var checks = 0;

function eq(name, actual, expected) {
    checks++;
    if (actual !== expected) {
        failures++;
        print("FAIL: " + name + " => " + JSON.stringify(actual) +
              " (expected " + JSON.stringify(expected) + ")");
    }
}

function* base() {
    yield 1;
    yield 2;
    return "end";
}

function* rec(n) {
    return yield* (n ? rec(n - 1) : base());
}

// (a) The minimal repro: one level of self-recursion. This threw
// "Maximum call stack size exceeded" before the fix.
var it = rec(1);
var r = it.next();
eq("rec(1) first value", r.value, 1);
eq("rec(1) first done", r.done, false);

// (b) Drive the delegation to completion at several depths: values and the
// final return value must flow all the way up the chain unchanged, and each
// depth must yield exactly the same sequence as a non-recursive yield*.
for (var d = 0; d <= 4; d++) {
    var iter = rec(d);
    var seen = [];
    var step;
    while (!(step = iter.next()).done) {
        seen.push(step.value);
    }
    eq("rec(" + d + ") yielded values", seen.join(","), "1,2");
    eq("rec(" + d + ") return value", step.value, "end");
    // Exhausted generators stay done.
    var after = iter.next();
    eq("rec(" + d + ") done sticks", after.done, true);
    eq("rec(" + d + ") done value", after.value, undefined);
}

// (c) Values sent in with .next(v) must traverse every level of the chain and
// reach the innermost generator, and its return value must come back out.
function* echo() {
    var a = yield 1;
    var b = yield a;
    return b;
}

function* recEcho(n) {
    return yield* (n ? recEcho(n - 1) : echo());
}

var e = recEcho(3);
var e0 = e.next();
eq("recEcho first value", e0.value, 1);
eq("recEcho first done", e0.done, false);
var e1 = e.next("A");
eq("recEcho sent value round trip", e1.value, "A");
eq("recEcho second done", e1.done, false);
var e2 = e.next("B");
eq("recEcho return value", e2.value, "B");
eq("recEcho final done", e2.done, true);

// (d) The delegating generator's own return value is the yield* result, so a
// level that post-processes it must still see the inner return.
function* wrap(n) {
    var inner = yield* (n ? wrap(n - 1) : base());
    return inner + "!";
}

var w = wrap(2);
var wseen = [];
var wstep;
while (!(wstep = w.next()).done) {
    wseen.push(wstep.value);
}
eq("wrap yielded values", wseen.join(","), "1,2");
eq("wrap nests return values", wstep.value, "end!!!");

if (failures === 0) {
    print("PASS generator_recursive_yield_star (" + checks + " checks)");
} else {
    print("FAILURES: " + failures);
    throw new Error("generator_recursive_yield_star failed");
}
