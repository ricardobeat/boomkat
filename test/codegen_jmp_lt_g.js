// Behavioural pair for test/golden_bytecode/jmp_lt_g.js.
//
// The golden pins the fused JMP_LT_G and its offset; this file pins the
// ANSWERS, so regenerating the golden cannot quietly make a broken loop the
// contract.
//
// JMP_LT_G folds `GETGLOBAL_PRIM rX, S` + `JMP_LT off, rB, rX` into one
// two-word op and carries the branch offset over untouched. That works only
// because the fused op branches relative to i+2 once both words are consumed,
// matching the base the unfused JMP_LT used at i+1. An off-by-one in that
// carry-over cancels itself on a flat loop, so the cases below vary the
// back-edge distance: nested loops, a labeled continue crossing two levels, a
// break out of the middle, and a bound reassigned while the loop runs.
//
// The bounds are plain numeric globals with no eval/globalThis/Function/with
// in the file, which is what lets the prim-slot proof emit the fusable
// GETGLOBAL_PRIM form in the first place. Adding any of those constructs
// silently un-fuses every case here and the test would still pass, so the
// golden is the half that proves the fusion fires.

var pass = 0, fail = 0;

function assert(cond, msg) {
  if (cond) { pass++; }
  else { fail++; print("FAIL: " + msg); }
}

function eq(actual, expected, msg) {
  assert(actual === expected, msg + " (expected " + expected + ", got " + actual + ")");
}

// --- Flat loop: the baseline the fused offset must not disturb ---
var n1 = 5, i1 = 0, s1 = 0;
while (i1 < n1) { s1 = s1 + i1; i1 = i1 + 1; }
eq(s1, 10, "flat loop sum");
eq(i1, 5, "flat loop counter after exit");

// --- Nested loops: inner and outer back-edges span different distances ---
var n2 = 4, m2 = 3, i2 = 0, j2 = 0, s2 = 0;
while (i2 < n2) {
  j2 = 0;
  while (j2 < m2) { s2 = s2 + 1; j2 = j2 + 1; }
  i2 = i2 + 1;
}
eq(s2, 12, "nested loop body count");
eq(i2, 4, "nested outer counter after exit");
eq(j2, 3, "nested inner counter after exit");

// --- Labeled continue: a second entry into the outer back-edge region ---
var n3 = 5, m3 = 4, i3 = 0, s3 = 0;
outer:
while (i3 < n3) {
  i3 = i3 + 1;
  var j3 = 0;
  while (j3 < m3) {
    j3 = j3 + 1;
    if (j3 === 2) { continue outer; }
    s3 = s3 + 1;
  }
}
eq(s3, 5, "labeled continue body count");
eq(i3, 5, "labeled continue outer counter");

// --- break out of the middle of the body ---
var n4 = 10, i4 = 0, s4 = 0;
while (i4 < n4) {
  i4 = i4 + 1;
  if (i4 === 4) { break; }
  s4 = s4 + i4;
}
eq(s4, 6, "break mid-body sum");
eq(i4, 4, "break mid-body counter");

// --- The bound is reassigned while the loop runs ---
// The fused op re-reads the global every iteration, so shortening the bound
// mid-loop must take effect immediately.
var n5 = 10, i5 = 0, s5 = 0;
while (i5 < n5) {
  s5 = s5 + i5;
  i5 = i5 + 1;
  if (i5 === 4) { n5 = 4; }
}
eq(s5, 6, "bound shortened mid-loop sum");
eq(i5, 4, "bound shortened mid-loop counter");
eq(n5, 4, "bound holds its new value");

// --- The bound is read again after the loop, on the fall-through path ---
var n6 = 6, i6 = 0, s6 = 0;
while (i6 < n6) { s6 = s6 + i6; i6 = i6 + 1; }
s6 = s6 + n6;
eq(s6, 21, "bound still readable after the loop");

// --- The bound is read inside the body, on the taken-branch path ---
var n7 = 5, i7 = 0, s7 = 0;
while (i7 < n7) { s7 = s7 + n7; i7 = i7 + 1; }
eq(s7, 25, "bound readable at the loop-body head");

// --- A non-numeric bound must keep JS comparison semantics ---
var n8 = "3", i8 = 0, s8 = 0;
while (i8 < n8) { s8 = s8 + 1; i8 = i8 + 1; }
eq(s8, 3, "string bound compares numerically");

var n9 = NaN, i9 = 0, s9 = 0;
while (i9 < n9) { s9 = s9 + 1; i9 = i9 + 1; }
eq(s9, 0, "NaN bound never enters the loop");

print('codegen_jmp_lt_g: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
