// Regression: for-in enumeration state must be released on EVERY loop exit,
// not just the exhausted one.
//
// The state (key snapshot + a temproot pin on the target) used to be freed
// only where NEXTFOR ran out of keys. Any abrupt exit — break, labeled break,
// return, a propagating throw, a labeled continue to an outer loop — left the
// state allocated AND the target permanently pinned, so `for (k in o) break;`
// (the standard "is this object non-empty" idiom) leaked without bound and the
// enumerated object could never be collected.
//
// State is now owned by the activation that created it, so cleanup happens
// either when the loop's own INITFOR runs again or when the frame is popped.
// These cases exercise every exit edge, at enough iterations that a per-exit
// leak is unmistakable in RSS, and assert that enumeration stays correct
// across re-entry (a broken release would surface as stale or missing keys).

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }

var N = 20000;
var obj = { a: 1, b: 2, c: 3 };

// --- break out of for-in, repeatedly -----------------------------------
var firstKeys = {};
for (var i = 0; i < N; i++) {
    for (var k in obj) { firstKeys[k] = (firstKeys[k] || 0) + 1; break; }
}
assert(firstKeys.a === N, 'break: first key should be "a" every time, got ' + JSON.stringify(firstKeys));

// --- return out of for-in ----------------------------------------------
function firstKey(o) { for (var k in o) { return k; } return null; }
var retBad = 0;
for (var i = 0; i < N; i++) { if (firstKey(obj) !== 'a') retBad++; }
assert(retBad === 0, 'return: ' + retBad + ' wrong first keys');

// --- throw propagating out of for-in ------------------------------------
var throwBad = 0;
function throwFrom(o) { for (var k in o) { throw k; } }
for (var i = 0; i < N; i++) {
    try { throwFrom(obj); throwBad++; } catch (e) { if (e !== 'a') throwBad++; }
}
assert(throwBad === 0, 'throw: ' + throwBad + ' unexpected outcomes');

// --- labeled continue to an OUTER loop ----------------------------------
var lcontCount = 0;
outer: for (var i = 0; i < N; i++) {
    for (var k in obj) { lcontCount++; continue outer; }
    lcontCount += 1000;   // never reached
}
assert(lcontCount === N, 'labeled continue: expected ' + N + ' body entries, got ' + lcontCount);

// --- labeled break out of a for-in --------------------------------------
var lbreakCount = 0;
for (var i = 0; i < N; i++) {
    lbl: for (var j = 0; j < 1; j++) {
        for (var k in obj) { lbreakCount++; break lbl; }
    }
}
assert(lbreakCount === N, 'labeled break: expected ' + N + ' body entries, got ' + lbreakCount);

// --- nested for-in where the INNER one breaks ---------------------------
// The inner loop's state must be released per outer iteration; only the outer
// loop's own re-entry can do that, so a missing release compounds.
var nestedOuter = 0, nestedInner = 0;
for (var i = 0; i < N; i++) {
    for (var a in obj) {
        nestedOuter++;
        for (var b in obj) { nestedInner++; break; }
    }
}
assert(nestedOuter === N * 3, 'nested outer: expected ' + (N * 3) + ', got ' + nestedOuter);
assert(nestedInner === N * 3, 'nested inner: expected ' + (N * 3) + ', got ' + nestedInner);

// --- break out of a for-in over a Proxy ---------------------------------
// A proxy's keys are virtual (trap results), so the pin/liveness assumptions
// differ from an ordinary object; the release path must handle it the same.
var proxy = new Proxy({ a: 1, b: 2, c: 3 }, {});
var proxyBad = 0;
for (var i = 0; i < N; i++) {
    var got = null;
    for (var k in proxy) { got = k; break; }
    if (got !== 'a') proxyBad++;
}
assert(proxyBad === 0, 'proxy break: ' + proxyBad + ' wrong first keys');

// --- for-in over a fresh object each iteration --------------------------
// Each iteration pins a DIFFERENT target. A leak here keeps every one of them
// alive, which is the unbounded-growth shape rather than a constant overhead.
var freshBad = 0;
for (var i = 0; i < N; i++) {
    var fresh = { p: i, q: i + 1 };
    for (var k in fresh) { if (fresh[k] !== i) freshBad++; break; }
}
assert(freshBad === 0, 'fresh target: ' + freshBad + ' wrong values');

// --- generator that suspends mid-enumeration, then completes ------------
// The body's frame is popped at each yield, so the state must MOVE to the
// generator; freeing it at the pop would be a use-after-free on resume.
function* genAll(o) { for (var k in o) yield k; }
var g = genAll(obj);
var seen = [];
var step = g.next();
while (!step.done) { seen.push(step.value); step = g.next(); }
assert(seen.join(',') === 'a,b,c', 'generator resume: expected a,b,c got ' + seen.join(','));

// Repeat enough that a per-generator leak shows, and confirm every run agrees.
var genBad = 0;
for (var i = 0; i < N; i++) {
    var acc = [];
    for (var v of genAll(obj)) acc.push(v);
    if (acc.join(',') !== 'a,b,c') genBad++;
}
assert(genBad === 0, 'generator repeat: ' + genBad + ' wrong enumerations');

// --- generator ABANDONED mid-enumeration --------------------------------
// Never resumed to exhaustion, so nothing but the generator's own teardown can
// release the state it is holding.
var abandonBad = 0;
for (var i = 0; i < N; i++) {
    var ga = genAll(obj);
    if (ga.next().value !== 'a') abandonBad++;   // suspended inside the for-in
}
assert(abandonBad === 0, 'abandoned generator: ' + abandonBad + ' wrong first keys');

// A generator explicitly closed mid-enumeration via .return() must also let go.
var closedBad = 0;
for (var i = 0; i < N; i++) {
    var gc2 = genAll(obj);
    gc2.next();
    var r = gc2.return('x');
    if (!r.done || r.value !== 'x') closedBad++;
}
assert(closedBad === 0, 'closed generator: ' + closedBad + ' wrong completions');

// --- enumeration still correct after all the churn ----------------------
var finalKeys = [];
for (var k in obj) finalKeys.push(k);
assert(finalKeys.join(',') === 'a,b,c', 'final enumeration: got ' + finalKeys.join(','));

// The target must still be fully intact — a botched pin release could have let
// it be collected out from under us.
assert(obj.a === 1 && obj.b === 2 && obj.c === 3, 'target object corrupted after churn');

print('forin_early_exit_cleanup: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
