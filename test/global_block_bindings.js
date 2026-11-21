// Block bindings of a classic script live in registers; its top-level lexical bindings stay
// global ones (visible to later scripts and through eval), and switch clauses keep their TDZ.
function assert(c, m) { if (!c) { print('FAIL: ' + m); throw new Error(m); } }
let topLet = 1;
const topConst = 2;
assert(globalThis.topLet === undefined, 'a script let is not a global property');
assert((0, eval)('topLet + topConst') === 3, 'indirect eval reaches top-level lexicals');
let total = 0;
for (let i = 0; i < 100; i++) { const d = i * 2; total += d; }
assert(total === 9900, 'block loop ' + total);
{ let hidden = 5; assert((0, eval)('typeof hidden') === 'undefined', 'indirect eval cannot see a block binding'); }
var r = 'none';
switch (1) { case 0: let a = 1; break; case 1: try { r = a; } catch (e) { r = e.constructor.name; } }
assert(r === 'ReferenceError', 'switch clause TDZ: ' + r);
globalThis.g = 'G';
var gr = 'none';
{ try { gr = g; } catch (e) { gr = e.constructor.name; } let g = 1; }
assert(gr === 'ReferenceError', 'block forward read with a global of that name: ' + gr);
print('global_block_bindings: ok');
