// Optimized functions with block scopes (PUSH_LEX, POP_LEX, INITTZ, PUTLEX, PUTLEX_C) and object
// literals with computed or method keys (INITPROP): closures that capture a block's let and const
// bindings, per-iteration loop bindings, `this` in arrows, a dead-zone read, and closures made in
// an optimized frame and called after it has returned. scripts/opt_exit_check.sh forces an exit
// at every point, which leaves for the baseline inside a block scope.
const saved = [];
function blocky(x, k) {
  switch (k & 7) {
    case 0: return x;
    case 1: { const y = x + 1; return ((z) => z + y + x)(2); }
    case 2: { let c = 0; const inc = () => ++c; inc(); inc(); return c + x; }
    case 3: { let v = x; saved.push(() => v); v += 1; return v; }
    case 4: { const fs = []; for (let i = 0; i < 3; i++) fs.push(() => i * x); return fs[0]() + fs[1]() + fs[2](); }
    case 5: return tdzc();
    case 6: { const o = { m() { return this.q + x; }, q: 3 }; return o.m(); }
  }
  let f = () => x * 2;
  return f();
}
function tdzc() { try { return tdz(); } catch (e) { return e instanceof ReferenceError ? -1 : -2; } }
function tdz() { { const g = () => w; const r = g(); const w = 1; return r; } }
const obj = {
  base: 10,
  run(n) {
    let s = 0;
    for (let i = 0; i < n; i++) {
      if ((i & 15) === 3) { const a = () => this.base + i; s += a(); }
      else s += i & 1;
    }
    return s;
  },
};
let acc = 0;
for (let i = 0; i < 200000; i++) acc += blocky(i, i);
let sv = 0; for (const f of saved) sv += f();
let ob = 0; for (let i = 0; i < 2000; i++) ob += obj.run(100);
print(acc, saved.length, sv, ob);
// A closure created in a block after the function has been optimized, called after the frame exits.
function maker(v) { if (v > 0) { let w = v * 3; return () => w++; } return null; }
let m = 0; const ms = []; for (let i = 1; i < 50000; i++) ms.push(maker(i));
for (const f of ms) { f(); m += f(); }
print(m);
