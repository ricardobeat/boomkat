// Conditional expression as an operand of a binary operator.
//
// Two independent peepholes in the compiler used to rewrite a ternary's
// join point without noticing it was a join point:
//
//   1. Copy-propagation (context.c3) collapsed `LDREG rT=rS ; ADD rD=rD,rT`
//      into `ADD rD=rD,rS` and NOP'd the move. For a ternary, `LDREG rT=rS`
//      IS the false arm's join copy: each arm computes into its own scratch
//      rS and copies into the shared result rT. The true arm jumps straight
//      onto the consumer, having written rT and never rS, so it read the
//      false arm's leftover scratch.
//   2. LDINT+ADD -> ADDI fusion (fusion.c3) baked the false arm's literal
//      into the join instruction as an immediate, so `5 + (c ? 10 : 20)`
//      became `ADDI r=r,20` for BOTH arms.
//
// Both were silent: no error, no crash, just the false arm's value for
// every condition. `(c ? a : b) + x` (ternary on the LEFT) was unaffected,
// because there the join copy is not adjacent to its consumer.
//
// Both peepholes now consult the shared jump-target bitset
// (fusion.c3 build_jump_targets) and decline to rewrite across a join.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); } }
function eq(actual, expected, msg) {
    assert(actual === expected, msg + ': expected ' + expected + ', got ' + actual);
}

var t = true, f = false;

// --- ternary as the RIGHT operand (the regressing position) ---
eq(5 + (true ? 10 : 20), 15, '5 + (true?10:20)');
eq(5 + (false ? 10 : 20), 25, '5 + (false?10:20)');
eq(5 - (true ? 10 : 20), -5, '5 - (true?10:20)');
eq(5 - (false ? 10 : 20), -15, '5 - (false?10:20)');
eq(5 * (true ? 10 : 3), 50, '5 * (true?10:3)');
eq(5 * (false ? 10 : 3), 15, '5 * (false?10:3)');
eq(20 / (true ? 10 : 5), 2, '20 / (true?10:5)');
eq(20 % (true ? 7 : 3), 6, '20 % (true?7:3)');
eq(2 ** (true ? 3 : 5), 8, '2 ** (true?3:5)');
eq(1 << (true ? 3 : 5), 8, '1 << (true?3:5)');
eq(64 >> (true ? 3 : 5), 8, '64 >> (true?3:5)');
eq(-64 >>> (true ? 28 : 30), 15, '-64 >>> (true?28:30)');
eq(12 & (true ? 10 : 3), 8, '12 & (true?10:3)');
eq(12 | (true ? 10 : 3), 14, '12 | (true?10:3)');
eq(12 ^ (true ? 10 : 3), 6, '12 ^ (true?10:3)');
eq(7 < (true ? 10 : 3), true, '7 < (true?10:3)');
eq(7 > (true ? 10 : 3), false, '7 > (true?10:3)');
eq(7 <= (true ? 7 : 3), true, '7 <= (true?7:3)');
eq(7 >= (true ? 10 : 3), false, '7 >= (true?10:3)');
eq(10 == (true ? 10 : 3), true, '10 == (true?10:3)');
eq(10 === (true ? 10 : 3), true, '10 === (true?10:3)');
eq('x' + (true ? 'a' : 'b'), 'xa', "'x' + (true?'a':'b')");
eq('x' + (false ? 'a' : 'b'), 'xb', "'x' + (false?'a':'b')");

// --- computed conditions: the branch is not constant-foldable ---
eq(5 + ((1 < 2) ? 10 : 20), 15, '5 + ((1<2)?10:20)');
eq(5 + ((2 < 1) ? 10 : 20), 25, '5 + ((2<1)?10:20)');
eq(5 + (t ? 10 : 20), 15, '5 + (t?10:20)');
eq(5 + (f ? 10 : 20), 25, '5 + (f?10:20)');

// --- ternary as the LEFT operand (was already correct; guard it) ---
eq((true ? 10 : 20) + 5, 15, '(true?10:20) + 5');
eq((false ? 10 : 20) + 5, 25, '(false?10:20) + 5');
eq((true ? 10 : 20) - 5, 5, '(true?10:20) - 5');

// --- ternary on BOTH sides ---
eq((true ? 10 : 3) + (true ? 5 : 2), 15, 'both, both true');
eq((true ? 10 : 3) + (false ? 5 : 2), 12, 'both, T then F');
eq((false ? 10 : 3) + (true ? 5 : 2), 8, 'both, F then T');
eq((false ? 10 : 3) + (false ? 5 : 2), 5, 'both, both false');
eq((t ? 10 : 3) - (t ? 5 : 2), 5, 'both computed, subtract');

// --- nested / chained ternaries in right-operand position ---
eq(7 + (true ? 1 : true ? 2 : 3), 8, 'chained, first arm');
eq(7 + (false ? 1 : true ? 2 : 3), 9, 'chained, second arm');
eq(7 + (false ? 1 : false ? 2 : 3), 10, 'chained, third arm');
eq(7 + (true ? (true ? 1 : 2) : (true ? 3 : 4)), 8, 'nested true/true');
eq(7 + (true ? (false ? 1 : 2) : (true ? 3 : 4)), 9, 'nested true/false');
eq(7 + (false ? (true ? 1 : 2) : (false ? 3 : 4)), 11, 'nested false/false');
eq(7 - (t ? 1 : 2) - (t ? 4 : 8), 2, 'two ternaries, chained subtract');

// --- ternary whose branches are themselves binary expressions ---
eq(7 + (true ? 2 + 8 : 1 + 2), 17, 'arm is a binary expr, true');
eq(7 + (false ? 2 + 8 : 1 + 2), 10, 'arm is a binary expr, false');
eq(7 * (t ? 2 * 3 : 4 * 5), 42, 'arm is a product, true');

// --- side-effecting branches: only the taken arm must run ---
var log = [];
function sideA() { log.push('A'); return 10; }
function sideB() { log.push('B'); return 3; }
log = [];
eq(7 + (true ? sideA() : sideB()), 17, 'side-effecting, true value');
eq(log.join(','), 'A', 'side-effecting, true branch only');
log = [];
eq(7 + (false ? sideA() : sideB()), 10, 'side-effecting, false value');
eq(log.join(','), 'B', 'side-effecting, false branch only');

// --- compound assignment (the += form the bug was first seen in) ---
var d;
d = 5; d += true ? 10 : 20; eq(d, 15, 'd += true?10:20');
d = 5; d += false ? 10 : 20; eq(d, 25, 'd += false?10:20');
d = 5; d += (1 < 2) ? 10 : 20; eq(d, 15, 'd += (1<2)?10:20');
d = 5; d -= true ? 10 : 20; eq(d, -5, 'd -= true?10:20');
d = 5; d *= true ? 10 : 3; eq(d, 50, 'd *= true?10:3');
d = 20; d /= true ? 10 : 5; eq(d, 2, 'd /= true?10:5');
d = 12; d &= true ? 10 : 3; eq(d, 8, 'd &= true?10:3');
d = 1; d <<= true ? 3 : 5; eq(d, 8, 'd <<= true?3:5');

var obj = { v: 5 };
obj.v += true ? 10 : 20; eq(obj.v, 15, 'obj.v += true?10:20');
var arr = [5];
arr[0] += true ? 10 : 20; eq(arr[0], 15, 'arr[0] += true?10:20');

// --- accumulation in a loop: the join is inside a backward branch ---
var b = 0;
b = b + (true ? 1 : 0);
eq(b, 1, 'b = b + (true?1:0)');

var s = 0;
for (var i = 0; i < 3; i++) { s = s + (i < 1 ? 100 : 7); }
eq(s, 114, 'loop body accumulates through a ternary');

var n = 0, k = 0;
while (k < (true ? 3 : 9)) { n += k; k++; }
eq(n, 3, 'ternary in a while condition');

var m = 0;
for (var j = 0; j < (t ? 4 : 9); j++) { m += (j % 2 === 0 ? 10 : 1); }
eq(m, 22, 'ternary in a for condition and in the body');

var dw = 0, di = 0;
do { dw += (t ? 1 : 4); di++; } while (di < (t ? 2 : 5));
eq(dw, 2, 'ternary in a do-while condition');

// --- ternary via a temp must stay correct too ---
var tmp = true ? 10 : 20;
var viaTemp = 5;
viaTemp += tmp;
eq(viaTemp, 15, 'ternary through an explicit temp');

print('ternary_binary_operand: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
