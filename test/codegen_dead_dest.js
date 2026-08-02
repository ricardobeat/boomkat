// Behavioural test for liveness-based dead-destination elimination
// (src/compiler/moveelim.c3). The pass NOPs an `LDREG rDst=rT` whose rDst is
// not live-out of the copy; these cases pin the LIVE side: every copy whose
// destination is later read must survive, or the observable value changes.
// The dead side (an expression-statement `sum += v` whose result is thrown
// away) is exercised too, since a wrong elimination there corrupts `sum`.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// ── Dead destination: expression-statement accumulate ────────────────────
// The `A += 2` result is discarded; only A is live. The copy of the ADD
// result into the statement-value register is dead and must be removable
// WITHOUT disturbing A's accumulation.
var A = 0;
for (var i = 0; i < 10; i++) { A += 2; }
eq(A, 20, "dead expression-statement accumulate");

// ── Live destination via assignment: the value is captured each pass ─────
var B = 0, bx = 0;
for (var i = 0; i < 10; i++) { bx = (B += 2); }
eq(B, 20, "assigned accumulate, source");
eq(bx, 20, "assigned accumulate, captured value");

// ── Live destination as a branch condition ───────────────────────────────
var C = 0, cT = 0, cF = 0;
for (var i = 0; i < 4; i++) {
  if ((C += 1) % 2) { cT++; } else { cF++; }
}
eq(C, 4, "condition accumulate, source");
eq(cT, 2, "condition accumulate, odd passes");
eq(cF, 2, "condition accumulate, even passes");

// ── Live destination as a call argument ──────────────────────────────────
var D = 0;
function capt(x) { return x; }
var dR = capt(D += 5);
eq(D, 5, "call-argument accumulate, source");
eq(dR, 5, "call-argument accumulate, passed value");

// ── Converging branch: post-join copy is a jump target ───────────────────
// Both arms write r, then a single copy feeds the return. A branch lands on
// the copy slot itself, so it must run for whichever arm took control.
function pick(c) {
  var r;
  if (c) { r = 11; } else { r = 22; }
  return r;
}
eq(pick(true), 11, "converging branch copy, true arm");
eq(pick(false), 22, "converging branch copy, false arm");

// ── Nested ternary: a branch converges onto the outer join copy ──────────
// `n > 90 ? 1 : n > 80 ? 2 : 3` compiles to two join copies: the inner one
// (`LDREG r6 = r7`) feeds the outer one (`LDREG r3 = r6`), and the inner
// true arm's JUMP lands directly on the outer copy slot. Retargeting the
// inner join copy into r3 (the outer copy's destination) and NOPing the
// outer copy is only sound when every path through the outer copy also ran
// the retargeted producer; the jump-in path did not, so it would return a
// register that was never written. This is the case that pins the
// jump_targets[k] guard in run_move_elimination: disabling it turns
// grade(85) from 2 into undefined.
function grade(n) { return n > 90 ? 1 : n > 80 ? 2 : 3; }
eq(grade(95), 1, "nested ternary, outer true arm");
eq(grade(85), 2, "nested ternary, inner true arm");
eq(grade(70), 3, "nested ternary, false arm");

// ── Loop sum read after the loop: destination live across the back-edge ──
var s = 0;
for (var i = 0; i < 3; i++) { s = s + i; }
eq(s, 3, "loop sum read after loop");

// ── Returned copy: the LDREG feeds RET directly ──────────────────────────
function add(a, b) { var r = a + b; return r; }
eq(add(2, 3), 5, "returned copy");

// ── Spread tail: trailing non-spread arg after a large spread ────────────
// The call-window liveness must keep the argument slots live while the
// producer-retarget liveness still collapses the literal write below
// first_arg. Regression for the `f(1,...a,99)` shape.
function spreadTest() {
  var arr = [2, 3, 4, 5];
  function spreadArgs() { return arguments.length + ":" + arguments[4] + ":" + arguments[5]; }
  return spreadArgs(1, ...arr, 99);
}
eq(spreadTest(), "6:5:99", "spread tail arg after large spread");

// High register pressure: many globals push the trailing-arg temp up into
// the spread's runtime dest window, which used to clobber an already-written
// argument slot (`args[4]=99` instead of `args[4]=5`). The trailing arg is
// now compiled into the reserved below-first_arg evaluation region.
var hp0=0,hp1=0,hp2=0,hp3=0,hp4=0,hp5=0,hp6=0,hp7=0,hp8=0,hp9=0;
var hp10=0,hp11=0,hp12=0,hp13=0,hp14=0,hp15=0,hp16=0,hp17=0,hp18=0,hp19=0;
var hp20=0,hp21=0,hp22=0,hp23=0,hp24=0,hp25=0,hp26=0,hp27=0,hp28=0,hp29=0;
var hpArr = [2, 3, 4, 5];
function hpArgs() {
  var s = arguments.length;
  for (var i = 0; i < arguments.length; i++) { s += ":" + arguments[i]; }
  return s;
}
eq(hpArgs(1, ...hpArr, 99), "6:1:2:3:4:5:99", "high-pressure spread tail, single trailing");
eq(hpArgs(...hpArr, 2, 3, 4, 5, 6, 7, 8), "11:2:3:4:5:2:3:4:5:6:7:8", "high-pressure spread tail, many trailing");
eq(hpArgs(...hpArr, 99), "5:2:3:4:5:99", "high-pressure spread tail, no leading");

print('codegen_dead_dest: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
