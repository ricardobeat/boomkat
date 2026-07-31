// Regression: a generator's Catcher chain must be released on every teardown
// path, and a suspended body's chain must stay visible to the GC.
//
// A generator body that suspends inside a try hands its Catcher chain to the
// GeneratorState (chains_save_to_gen), which is the sole owner while the body
// sleeps. Nothing used to free it: gs_release drained the for-in chain but not
// the catcher chain, so a generator abandoned while suspended — `var it = g();
// it.next();` and nothing more, the ordinary way to take one value from an
// infinite sequence — leaked one Catcher per instance, plus whatever exception
// a parked finally still held in thrown_val. Peak RSS over 400k abandonments
// was 3.1x the same loop run to exhaustion.
//
// The same chain was also invisible to the mark phase: mark_activation_fields
// marks a running frame's catchers, but mark_generator_state marked everything
// on the GeneratorState EXCEPT gs.cat, so an exception parked in a suspended
// body's finally was rooted by nothing at all.
//
// The leak itself is not observable from script (no GC trigger or heap-stat
// builtin, and neither WeakRef nor FinalizationRegistry clears deterministically),
// exactly as for the for-in leak this mirrors, so the memory bound lives in
// scripts/check_generator_catcher_rss.sh. What is asserted here is the
// semantics that the ownership change must not break: the catcher chain is
// ALIASED at suspend rather than moved, because .throw()/.return() re-enter the
// still-live activation hunting for a catcher, and it is only cleared on resume.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }

var N = 5000;

// --- abandoned while suspended inside a try ----------------------------
// The leaking shape: each instance allocates a Catcher, suspends holding it,
// and is dropped without ever resuming.
function* abandoned() {
    try { yield 1; yield 2; } catch (e) { yield 'caught'; }
}
var abandonBad = 0;
for (var i = 0; i < N; i++) {
    var it = abandoned();
    if (it.next().value !== 1) abandonBad++;
}
assert(abandonBad === 0, 'abandoned generator: ' + abandonBad + ' wrong first values');

// --- try/catch inside a suspended generator still works ----------------
// The constraint the fix must not break. .throw() resumes a body that is
// parked inside a try; the catcher has to still be reachable from the
// activation, which is why the save aliases rather than moves.
var throwBad = 0;
for (var i = 0; i < N; i++) {
    var t = abandoned();
    t.next();
    if (t.throw(new Error('x')).value !== 'caught') throwBad++;
}
assert(throwBad === 0, 'throw into suspended generator: ' + throwBad + ' not caught');

// --- .return() into a suspended try ------------------------------------
function* withFinally() {
    var ran = false;
    try { yield 1; } finally { ran = true; }
    yield ran;
}
var returnBad = 0;
for (var i = 0; i < N; i++) {
    var r2 = withFinally();
    r2.next();
    var res = r2.return('done');
    if (!res.done || res.value !== 'done') returnBad++;
}
assert(returnBad === 0, 'return into suspended generator: ' + returnBad + ' wrong completions');

// --- resume, complete, resume again: ownership handed back -------------
// chains_restore_from_gen clears gs.cat so the activation's own pop frees the
// chain. If it did not, gs_release would free it a second time.
var cycleBad = 0;
for (var i = 0; i < N; i++) {
    var c = abandoned();
    if (c.next().value !== 1) cycleBad++;
    if (c.next().value !== 2) cycleBad++;
    if (!c.next().done) cycleBad++;
}
assert(cycleBad === 0, 'run to exhaustion: ' + cycleBad + ' wrong steps');

// --- exception parked across a suspend ---------------------------------
// A yield inside a finally that is routing a throw leaves the exception in
// Catcher.thrown_val, on the GeneratorState, referenced by nothing else.
// mark_generator_state has to mark it or it is swept while the body sleeps.
function* parked() {
    try {
        try { throw new Error('parked-payload'); }
        finally { yield 'suspended'; }
    } catch (e) { yield e.message; }
}
var parkedBad = 0;
for (var i = 0; i < 200; i++) {
    var p = parked();
    if (p.next().value !== 'suspended') { parkedBad++; continue; }
    // Allocate hard between the suspend and the resume so a safepoint GC runs
    // while the exception is reachable only through gs.cat.
    for (var j = 0; j < 200; j++) { var junk = { a: [j, j, j], b: 's' + j, c: { d: j } }; }
    if (p.next().value !== 'parked-payload') parkedBad++;
}
assert(parkedBad === 0, 'exception parked across suspend: ' + parkedBad + ' lost');

// --- nested try inside a generator -------------------------------------
// Two catchers on one chain, so the drain has to walk it rather than free
// only the head.
function* nested() {
    try { try { yield 1; } catch (e) { yield 'inner'; } } finally { }
}
var nestedBad = 0;
for (var i = 0; i < N; i++) {
    var n = nested();
    n.next();
    if (n.throw(new Error('y')).value !== 'inner') nestedBad++;
}
assert(nestedBad === 0, 'nested try in generator: ' + nestedBad + ' not caught by inner');

// --- for-in and catchers on the same suspended generator ---------------
// Both chains move/alias in one call (chains_save_to_gen), so a body holding
// both must release both.
var target = { a: 1, b: 2, c: 3 };
function* both(o) {
    try { for (var k in o) { yield k; } } catch (e) { yield 'err'; }
}
var bothBad = 0;
for (var i = 0; i < N; i++) {
    var b = both(target);
    if (b.next().value !== 'a') bothBad++;
}
assert(bothBad === 0, 'for-in + catcher abandoned: ' + bothBad + ' wrong first keys');
assert(target.a === 1 && target.b === 2 && target.c === 3, 'target corrupted after churn');

print('generator_catcher_cleanup: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
