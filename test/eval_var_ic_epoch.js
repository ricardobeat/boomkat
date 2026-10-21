// Eval declarations retire variable inline caches.
//
// A sloppy direct eval that adds a `var` can shadow a binding a cache already
// resolved further out, without changing the shape the cache compares. The
// heap retires every variable cache at once by advancing the recycle epoch,
// and the reads below must all see the new binding.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

var x = 'global';
function reader() { return x; }
function shadowLater(code) {
    var seen = [];
    for (var i = 0; i < 3; i++) seen.push(x);
    eval(code);
    for (var i = 0; i < 3; i++) seen.push(x);
    return seen.join(',');
}
eq(shadowLater('var x = "local"'), 'global,global,global,local,local,local', 'eval var shadows global');
eq(reader(), 'global', 'global untouched');

// Nested: an inner closure's cache resolved to the global before the eval.
function outer() {
    function inner() { return x; }
    var before = inner() + inner();
    eval('var x = "outer"');
    return before + '|' + inner() + inner();
}
eq(outer(), 'globalglobal|outerouter', 'closure cache retired');

// A global eval adding a new global after reads of a property with the same
// name through the prototype of the global object.
Object.prototype.late = 'proto';
function readLate() { return late; }
eq(readLate() + readLate(), 'protoproto', 'inherited global');
(0, eval)('var late = "own"');
eq(readLate(), 'own', 'global eval var');

// Many evals in a row keep working with cached reads in between.
var total = 0;
function counter(n) { for (var k = 0; k < n; k++) { eval('var c' + k + ' = ' + k); total += x.length; } }
counter(20);
eq(total, 20 * 6, 'reads between evals');

print('eval_var_ic_epoch: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
