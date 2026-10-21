// instanceof on primitives, typeof, and closure reads across activations.
//
// `v instanceof F` for a primitive v bailed to the switch, as did every
// typeof; Scheme-compiled code runs both constantly. A closure reading a
// variable of an enclosing per-call scope missed its cache on every new
// activation unless the owning scope was the very record the cache was filled
// with; an owner on the same shape now re-arms the entry.

var pass = 0;
var fail = 0;

function eq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print('FAIL: ' + msg + ' (got ' + actual + ', want ' + expected + ')'); }
}

function Pair(a, d) { this.car = a; this.cdr = d; }
function len(l) { var n = 0; while (l instanceof Pair) { n++; l = l.cdr; } return n; }
var values = [null, undefined, 1, 1.5, 'x', true, Symbol('s'), 10n];
var list = null;
for (var i = 0; i < 300; i++) {
    list = new Pair(i, list);
    for (var j = 0; j < values.length; j++) {
        if (values[j] instanceof Pair) eq(true, false, 'primitive instanceof ' + j);
    }
}
eq(len(list), 300, 'list walk');

// A non-callable right side still throws; @@hasInstance and bound functions
// keep their own semantics.
var threw = 0;
for (var i = 0; i < 100; i++) { try { 1 instanceof {}; } catch (e) { threw += e instanceof TypeError; } }
eq(threw, 100, 'non-callable right side');
var Even = { [Symbol.hasInstance]: function (v) { return v % 2 === 0; } };
var Bound = Pair.bind(null);
var hits = 0;
for (var i = 0; i < 100; i++) hits += (i instanceof Even) + (new Pair(1, null) instanceof Bound) + (i instanceof Bound);
eq(hits, 50 + 100, 'hasInstance and bound');

var kinds = [undefined, null, true, 1, 1.5, 'a', Symbol(), 1n, {}, [], function () {}, Pair];
var seen = '';
for (var r = 0; r < 100; r++) {
    seen = '';
    for (var i = 0; i < kinds.length; i++) seen += typeof kinds[i] + ',';
}
eq(seen, 'undefined,object,boolean,number,number,string,symbol,bigint,object,object,function,function,', 'typeof');

// Closures over per-call scopes, as Scheme loops nest them.
function walker(xs, base) {
    var total = base, i;
    var step = function (k) { var acc; acc = total + xs[k]; return acc; };
    for (i = 0; i < xs.length; i++) total = step(i);
    return total;
}
var t = 0;
for (var r = 0; r < 300; r++) t += walker([1, 2, 3], r);
eq(t, 300 * 6 + 299 * 300 / 2, 'closure reads of an outer scope');

// Same function, scopes that diverge in shape: a direct eval adds a binding
// to some activations only. Reads must not use another shape's slot.
function shaped(flag, v) {
    var a = v;
    if (flag) eval('var extra = 100');
    var b = v * 2;
    return function () { return a + b + (typeof extra === 'undefined' ? 0 : extra); };
}
var s = 0;
for (var r = 0; r < 300; r++) s += shaped(r % 3 === 0, r)();
eq(s, 3 * 299 * 300 / 2 + 100 * 100, 'diverging scope shapes');

print('threaded_scope_reads: ' + pass + ' passed, ' + fail + ' failed');
if (fail > 0) { print('SOME TESTS FAILED'); throw new Error('FAIL'); }
