// Top-level and block lexical bindings a module keeps in registers when nothing else reaches them
// by name: not exported, not captured by a closure, no eval or with. Each case checks the
// semantics such a binding must keep (TDZ, const, shadowing, live exports, captures).
import { readLive, bumpFromDep } from './dep.js';

function assert(c, m) { if (!c) throw new Error('FAIL: ' + m); }
function errName(f) { try { f(); return 'none'; } catch (e) { return e.constructor.name; } }

globalThis.early = 'GLOBAL';
globalThis.k = 'GLOBAL';

// Forward reads, writes and typeof of a private binding throw, even with a global of that name.
let fwdRead = 'none', fwdWrite = 'none', fwdTypeof = 'none';
try { fwdRead = early; } catch (e) { fwdRead = e.constructor.name; }
try { early = 1; } catch (e) { fwdWrite = e.constructor.name; }
try { fwdTypeof = typeof early; } catch (e) { fwdTypeof = e.constructor.name; }
let early = 2;
assert(fwdRead === 'ReferenceError', 'forward read: ' + fwdRead);
assert(fwdWrite === 'ReferenceError', 'forward write: ' + fwdWrite);
assert(fwdTypeof === 'ReferenceError', 'forward typeof: ' + fwdTypeof);
assert(early === 2, 'read after declaration');

// A private const still rejects assignment, at top level and in a block.
const k = 5;
let constTop = 'none';
try { k = 6; } catch (e) { constTop = e.constructor.name; }
assert(constTop === 'TypeError' && k === 5, 'top-level const assignment: ' + constTop);
{
    const inner = 1;
    let constBlock = 'none';
    try { inner = 2; } catch (e) { constBlock = e.constructor.name; }
    assert(constBlock === 'TypeError' && inner === 1, 'block const assignment: ' + constBlock);
}

// A class declaration is in its dead zone before it runs.
assert(errName(() => Late) === 'ReferenceError', 'class read in a closure before its declaration');
let lateTop = 'none';
try { lateTop = typeof Late; } catch (e) { lateTop = e.constructor.name; }
class Late { static v() { return 3; } }
assert(lateTop === 'ReferenceError' && Late.v() === 3, 'class before declaration: ' + lateTop);

// The loop that motivated this: block bindings and a top-level accumulator in registers.
let total = 0;
for (let i = 0; i < 1000; i++) { const sq = i * i; total += sq; }
assert(total === 332833500, 'loop total ' + total);

// Destructuring assignment writes the binding every later read sees.
let dx = 0, dy = 0;
[dx, dy] = [10, 20];
({ dx, dy } = { dx: dy, dy: dx });
assert(dx === 20 && dy === 10, 'destructuring ' + dx + ',' + dy);

// Captured bindings, top-level and per iteration, stay shared with their closures.
let shared = 1;
const getShared = () => shared;
shared = 7;
assert(getShared() === 7, 'closure sees the assignment');
const fns = [];
for (let j = 0; j < 3; j++) fns.push(() => j);
for (const n of [10, 20]) fns.push(() => n);
assert(fns.map(f => f()).join() === '0,1,2,10,20', 'per-iteration captures ' + fns.map(f => f()).join());

// A hoisted function reads a top-level binding before and after its initialization.
assert(errName(readLater) === 'ReferenceError', 'hoisted function before initialization');
let later = 'L';
function readLater() { return later; }
assert(readLater() === 'L', 'hoisted function after initialization');

// A block binding shadows a top-level one of the same name and leaves it intact.
let shadow = 'outer';
{ let shadow = 'inner'; assert(shadow === 'inner', 'inner shadow'); }
for (let shadow = 0; shadow < 2; shadow++) {}
assert(shadow === 'outer', 'outer binding after shadows');

// switch: a clause entered past an earlier clause's initializer sees the binding uninitialized.
function sw(v) {
    let r = 'none';
    switch (v) { case 0: let a = 'A'; r = a; break; case 1: try { r = a; } catch (e) { r = e.constructor.name; } }
    return r;
}
assert(sw(0) === 'A' && sw(1) === 'ReferenceError', 'switch in a function: ' + sw(1));
let swTop = 'none';
switch (1) { case 0: let b = 'B'; break; case 1: try { swTop = b; } catch (e) { swTop = e.constructor.name; } }
assert(swTop === 'ReferenceError', 'switch at top level: ' + swTop);

// An exception out of a block whose scope was compiled away, and a labeled break past a declaration.
let caught = 'none';
try { { let t = 1; if (t) throw new Error('x'); } } catch (e) { caught = e.message; }
assert(caught === 'x', 'throw out of a block');
let afterBreak = 0;
out: { afterBreak = 1; if (afterBreak) break out; let never = 2; afterBreak = never; }
assert(afterBreak === 1, 'labeled break');

// An exported let stays a live binding for importers.
export let live = 1;
export function bumpLive() { live++; }
assert(readLive() === 1, 'export initial');
assert(bumpFromDep() === 2 && live === 2, 'export live');

// Every assignment form writes a private top-level binding and a block one in place, refuses a
// const and throws in the dead zone (loop heads, update, compound and logical assignment).
const formsLog = [];
let fk = 'none', fv = 'none', fn_ = 1, fs = null, ft = 0, fcnt = 0;
for (fk in { a: 1, b: 2 }) fcnt++;
for (fv of [7, 8]) fcnt++;
for ([fn_, ft] of [[3, 4]]) fcnt++;
fn_++; ++fn_; fn_--; fn_ += 10; fn_ **= 2; fn_ ||= 0; fs ??= 'S'; ft &&= 5;
formsLog.push(fk, fv, fn_, fs, ft, fcnt, typeof fk);
{
    let bk, bv, bn = 1, bs, cnt2 = 0;
    for (bk in { x: 1 }) cnt2++;
    for (bv of 'pq') cnt2++;
    for ({ bn } of [{ bn: 6 }]) cnt2++;
    bn += 1; bs ??= 'B'; bs &&= bs + '!';
    formsLog.push(bk, bv, bn, bs, cnt2);
}
try { for (flate in { z: 1 }); } catch (e) { formsLog.push(e.constructor.name); }
try { for (flate of [1]); } catch (e) { formsLog.push(e.constructor.name); }
try { flate++; } catch (e) { formsLog.push(e.constructor.name); }
try { flate ??= 1; } catch (e) { formsLog.push(e.constructor.name); }
let flate = 0;
const fc = 1;
try { for (fc of [2]); } catch (e) { formsLog.push(e.constructor.name, fc); }
try { fc += 1; } catch (e) { formsLog.push(e.constructor.name, fc); }
try { fc ||= 3; formsLog.push('noop', fc); } catch (e) { formsLog.push(e.constructor.name, fc); }
if (formsLog.join(' ') !== 'b 8 196 S 5 5 string x q 7 B! 4 ReferenceError ReferenceError ReferenceError ReferenceError TypeError 1 TypeError 1 noop 1') throw new Error('FAIL: assignment targets: ' + formsLog.join(' '));
