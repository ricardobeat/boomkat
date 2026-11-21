// A module body with top-level await keeps its block bindings' scopes (prune_unobserved_environment_stores
// leaves an awaiting module alone); a module that evals keeps every binding reachable by name.
function assert(c, m) { if (!c) throw new Error('FAIL: ' + m); }
let total = 0;
for (let i = 0; i < 5; i++) { const step = await Promise.resolve(i); total += step; }
assert(total === 10, 'awaited loop ' + total);
let seen = 'unset';
{ let viaEval = 'E'; seen = eval('viaEval'); }
assert(seen === 'E', 'eval reads a block binding: ' + seen);
let top = 't';
assert(eval('top') === 't', 'eval reads a top-level binding');
