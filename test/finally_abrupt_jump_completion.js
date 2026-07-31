// A break/continue that does NOT leave the try/catch/finally region it is
// written in must not be routed through the enclosing finally handler. Routing
// it there made the VM pop and free the catcher carrying the in-flight
// completion, so `try { throw e } finally { while (1) break; }` silently
// swallowed `e`, `break` out of a switch inside a try ran the finally twice,
// and a plain nested-loop break inside a try turned a caught exception into an
// uncaught one. A for-of body additionally opens its own IteratorClose guard,
// whose ENDTRY the jump bypassed, leaving a stale catcher for the following
// ENDFINALLY to pop instead of its own.
//
// Runnable unmodified under node; the counts must match.
if (typeof print === 'undefined') { var print = function (s) { console.log(s); }; }

var pass = 0;
var fail = 0;

function assert(cond, label) {
  if (cond) { pass++; } else { fail++; print('  not ok: ' + label); }
}

function assertEq(actual, expected, label) {
  assert(actual === expected, label + ' — got ' + String(actual) + ', want ' + String(expected));
}

// --- the jump stays inside the finally: the try's throw must survive ---

function whileBreakInFinally() {
  try { throw new Error('P'); } finally { while (1) { break; } }
}
try { whileBreakInFinally(); assert(false, 'while-break in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'while-break in finally rethrows'); }

function forContinueInFinally() {
  try { throw new Error('P'); } finally { for (var i = 0; i < 3; i++) { if (i === 1) { continue; } } }
}
try { forContinueInFinally(); assert(false, 'for-continue in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'for-continue in finally rethrows'); }

function labeledBreakInFinally() {
  try { throw new Error('P'); } finally { L: { break L; } }
}
try { labeledBreakInFinally(); assert(false, 'labeled break in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'labeled break in finally rethrows'); }

function switchBreakInFinally() {
  try { throw new Error('P'); } finally { switch (1) { case 1: break; } }
}
try { switchBreakInFinally(); assert(false, 'switch break in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'switch break in finally rethrows'); }

function doWhileBreakInFinally() {
  try { throw new Error('P'); } finally { do { break; } while (0); }
}
try { doWhileBreakInFinally(); assert(false, 'do-while break in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'do-while break in finally rethrows'); }

// for-of in a finally also bypassed its own IteratorClose guard's ENDTRY.
function forOfBreakInFinally() {
  try { throw new Error('P'); } finally { for (var v of [1, 2, 3]) { break; } }
}
try { forOfBreakInFinally(); assert(false, 'for-of break in finally rethrows'); }
catch (e) { assertEq(e.message, 'P', 'for-of break in finally rethrows'); }

// The nested try/finally form the generator bug was first reported as.
function nestedFinallyBreak() {
  try {
    try { throw new Error('P'); } finally { for (var i = 0; i < 3; i++) { if (i === 1) { break; } } }
  } catch (e) { return 'caught:' + e.message; }
}
assertEq(nestedFinallyBreak(), 'caught:P', 'nested try/finally with break in finally');

// --- the jump stays inside the try body: the finally must run exactly once ---

function switchBreakInTry() {
  var log = [];
  for (var i = 0; i < 2; i++) {
    try {
      switch (i) { case 0: break; case 1: log.push('one'); }
      log.push('after' + i);
    } finally { log.push('f' + i); }
  }
  return log.join(',');
}
assertEq(switchBreakInTry(), 'after0,f0,one,after1,f1', 'switch break inside try runs finally once');

function nestedLoopBreakInTry() {
  var log = [];
  try {
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) { if (j === 1) { break; } log.push(i + ':' + j); }
    }
    throw new Error('P');
  } catch (e) { log.push('c:' + e.message); } finally { log.push('fin'); }
  return log.join(',');
}
assertEq(nestedLoopBreakInTry(), '0:0,1:0,2:0,c:P,fin', 'inner-loop break inside try keeps the throw catchable');

// --- the jump DOES leave the region: the finally must still be routed through ---

function labeledBreakOutOfTry() {
  var log = [];
  L: for (var i = 0; i < 3; i++) {
    try { log.push('t' + i); break L; } finally { log.push('f' + i); }
  }
  return log.join(',');
}
assertEq(labeledBreakOutOfTry(), 't0,f0', 'labeled break out of try still runs finally');

function breakOutOfTry() {
  var log = [];
  for (var i = 0; i < 3; i++) {
    try { log.push('t' + i); break; } finally { log.push('f' + i); }
  }
  return log.join(',');
}
assertEq(breakOutOfTry(), 't0,f0', 'unlabeled break out of try still runs finally');

function continueOutOfTry() {
  var log = [];
  for (var i = 0; i < 3; i++) {
    try { log.push('t' + i); continue; } finally { log.push('f' + i); }
  }
  return log.join(',');
}
assertEq(continueOutOfTry(), 't0,f0,t1,f1,t2,f2', 'continue out of try still runs finally');

function breakOutOfCatch() {
  var log = [];
  for (var i = 0; i < 3; i++) {
    try { throw new Error('e' + i); } catch (e) { log.push('c' + i); break; } finally { log.push('f' + i); }
  }
  return log.join(',');
}
assertEq(breakOutOfCatch(), 'c0,f0', 'break out of catch still runs finally');

function labeledContinueCrossingTry() {
  var log = [];
  L: for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
      try { log.push('' + i + j); continue L; } finally { log.push('f'); }
    }
  }
  return log.join(',');
}
assertEq(labeledContinueCrossingTry(), '00,f,10,f', 'labeled continue crossing a try runs finally');

// A `return` inside the finally still overrides the parked throw.
function returnInFinallyOverrides() {
  try { throw new Error('P'); } finally { return 'ret'; }
}
assertEq(returnInFinallyOverrides(), 'ret', 'return in finally overrides the parked throw');

// --- generator forms: the parked exception crosses a suspend boundary ---

function* genBreakInFinally() {
  try {
    try { throw new Error('P'); } finally { while (1) { yield 1; break; } }
  } catch (e) { return 'caught:' + e.message; }
}
var git = genBreakInFinally();
assertEq(git.next().value, 1, 'generator yields from inside the finally');
var gres = git.next();
assertEq(gres.value, 'caught:P', 'generator parked throw survives break in finally');
assertEq(gres.done, true, 'generator done after parked throw is caught');

function* genParkedPlain() {
  try {
    try { throw new Error('parked-payload'); } finally { yield 1; }
  } catch (e) { return e.message; }
}
var g2 = genParkedPlain();
g2.next();
assertEq(g2.next().value, 'parked-payload', 'parked exception survives a yield in the finally');

function* genNestedParked() {
  var log = [];
  try {
    try {
      try { throw new Error('P'); } finally { log.push('f3'); yield 1; }
    } finally { log.push('f2'); yield 2; }
  } catch (e) { return log.join(',') + '|' + e.message; }
}
var g3 = genNestedParked();
g3.next(); g3.next();
assertEq(g3.next().value, 'f3,f2|P', 'parked exception survives nested yielding finallys');

print('finally_abrupt_jump_completion: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
