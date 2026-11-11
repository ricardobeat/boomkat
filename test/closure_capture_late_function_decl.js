// A closure that reads a sibling function declaration is created before that
// declaration's binding is published (hoisted declarations are instantiated
// in reverse order), so its capture is resolved on first use. The binding it
// then caches must behave exactly like the by-name lookup: later assignments
// are seen, and bindings that can still change shape are never cached.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

function Outer() {
    function useLater(x) { return later(x); }
    function later(x) { return x + 1; }
    var results = [];
    for (var i = 0; i < 300; i++) results.push(useLater(i));
    ok(results[299] === 300, 'sibling declaration called through the capture');
    later = function (x) { return x * 2; };
    ok(useLater(21) === 42, 'reassigned declaration seen after caching');
    return useLater;
}
var escaped = Outer();
ok(escaped(5) === 10, 'escaped closure keeps the binding');

function Recursive() {
    function a(n) { return n === 0 ? 'done' : b(n - 1); }
    function b(n) { return a(n); }
    return a(500);
}
ok(Recursive() === 'done', 'mutually recursive declarations');

// A sloppy direct eval's var is configurable: it can be deleted, after which
// the name resolves further out.
var shadowed = 'global';
function WithEval() {
    eval('var shadowed = "local"');
    function read() { return shadowed; }
    var first = read();
    delete shadowed;
    return [first, read()];
}
var r = WithEval();
ok(r[0] === 'local' && r[1] === 'global', 'deleted eval var falls through: ' + r);

// Block-level function in sloppy mode (Annex B.3.3): published when the block
// is evaluated, after the closure that reads it.
function AnnexB() {
    function call() { return typeof inner === 'function' ? inner() : 'none'; }
    var before = call();
    { function inner() { return 'inner'; } }
    var after = call();
    return before + ',' + after;
}
ok(AnnexB() === 'none,inner', 'Annex B function published later: ' + AnnexB());

for (var k = 0; k < 3; k++) ok(Outer()(3) === 6, 'fresh activation #' + k);

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);
