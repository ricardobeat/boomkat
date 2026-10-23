function assert(value, message) { if (!value) throw new Error(message); }
var rootThis = this;
assert(rootThis === globalThis, 'sloppy Script root this');
function sloppy() { return this; }
assert(sloppy() === globalThis, 'sloppy function this');
function strict() { 'use strict'; return this; }
assert(strict() === undefined, 'strict function this');
function localEval() {
    var x = 11;
    assert(eval('x + 1') === 12, 'eval local read');
    eval('var added = 17; x = 19');
    assert(x === 19 && added === 17, 'eval local writes and declarations');
    return function () { return added + x; };
}
assert(localEval()() === 36, 'eval closure');
function strictEval() { 'use strict'; var x = 3; return eval('x + 4'); }
assert(strictEval() === 7, 'strict direct eval');
function spaced (x) { /* source retained */ return x + 2; }
assert(spaced.toString().indexOf('/* source retained */') >= 0, 'function source');
assert((0, eval)('this') === globalThis, 'indirect eval global');
print('PASS script image semantics');
