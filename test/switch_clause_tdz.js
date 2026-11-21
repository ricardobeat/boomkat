// A switch clause entered from its own test skips the initializers of the clauses above it: their
// let, const and class bindings are still in their dead zone there, also in a function's registers.
function g(v) { switch (v) { case 0: let a = 'A'; return a; case 1: try { return 'read:' + a; } catch (e) { return e.constructor.name; } } }
function w(v) { switch (v) { case 0: let a = 'A'; break; case 1: try { a = 2; return 'wrote'; } catch (e) { return e.constructor.name; } } }
function ft(v) { let r = []; switch (v) { case 0: let a = 'A'; r.push(a); case 1: r.push(a); a = 'B'; r.push(a); } return r.join(); }
function ty(v) { switch (v) { case 0: let a = 1; break; case 1: try { return typeof a; } catch (e) { return e.constructor.name; } } }
function cls(v) { switch (v) { case 0: class C {} break; case 1: try { return typeof C; } catch (e) { return e.constructor.name; } } }
function cst(v) { switch (v) { case 0: const k = 5; return k; default: try { return k; } catch (e) { return e.constructor.name; } } }
function loopy() { let s = 0; for (let i = 0; i < 4; i++) { switch (i & 1) { case 0: let t = i; s += t; break; case 1: s += 100; } } return s; }
const out = [g(0), g(1), w(1), ft(0), ty(1), cls(1), cst(0), cst(9), loopy()].join(' | ');
if (out !== 'A | ReferenceError | ReferenceError | A,A,B | ReferenceError | ReferenceError | 5 | ReferenceError | 202') throw new Error('FAIL: ' + out);
print('switch_clause_tdz: ok');
