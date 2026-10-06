// Generators fused into their for-of loop (src/compiler/generator_fusion.c3).
function check(got, want) { if (got !== want) throw new Error("got " + got + ", want " + want); }
function main() {
  function* range(n) { let i = 0; while (i < n) { yield i; i++; } }
  function* pair(a, b) { yield a; if (b === undefined) return; yield b; }
  function* scoped(n) { for (let i = 0; i < n; i++) { const sq = i * i; yield sq; } }
  // The loop body's names shadow the generator's locals.
  let i = 100, n = 7, out = [];
  for (const x of range(3)) { let i = x * 10; out.push(i + n); }
  check(out.join(), "7,17,27");
  check(i, 100);
  out = [];
  for (const x of pair(1)) out.push(x);
  for (const x of pair(2, 3)) out.push(x);
  check(out.join(), "1,2,3");
  out = [];
  for (const a of range(3)) for (const b of range(a)) out.push(a + ":" + b);
  check(out.join(), "1:0,2:0,2:1");
  out = [];
  outer: for (const a of [1, 2]) for (const b of scoped(5)) { if (b > 4) continue outer; out.push(a * b); }
  check(out.join(), "0,1,4,0,2,8");
  let s = 0;
  for (let x of range(10)) { if (x === 5) break; x++; s += x; }
  check(s, 15);
  return function () { for (const x of range(2)) s += x; return s; };
}
check(main()(), 16);
