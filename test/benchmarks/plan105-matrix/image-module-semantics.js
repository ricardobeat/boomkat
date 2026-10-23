function assert(value, message) { if (!value) throw new Error(message); }
assert(this === undefined, 'module root this');
function strict() { return this; }
assert(strict() === undefined, 'module function strictness');
function localEval() { var x = 11; return eval('x + 1'); }
assert(localEval() === 12, 'module local eval');
print('PASS module image semantics');
