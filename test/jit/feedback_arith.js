// Operand-class feedback: run each site in a different class, then dump with
//   boomkat --jit-dump-feedback --script test/jit/feedback_arith.js
function intadd(a, b) { return a + b; }
function dbladd(a, b) { return a + b; }
function stradd(a, b) { return a + b; }
function ovfadd(a, b) { return a + b; }
function dblsub(a, b) { return a - b; }
function dblmul(a, b) { return a * b; }
function dbllt(a, b) { return a < b; }
function dblor(a) { return a | 0; }
function neg(a) { return -a; }
function mixed(a, b) { return a + b; }
var s = 0;
for (var i = 0; i < 300; i++) {
  s += intadd(i, 1);
  dbladd(i + 0.5, 1.25);
  stradd("x", i);
  ovfadd(0x7fffffffffff, i + 1);
  dblsub(i + 0.5, 0.25);
  dblmul(i + 0.5, 2.5);
  dbllt(i + 0.5, 100);
  dblor(i + 0.5);
  neg(i + 0.5);
  mixed(i, i % 2 ? undefined : 1.5);
}
console.log(s);
