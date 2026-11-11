// lastIndex reads and writes inside the RegExp builtins take slot 0 directly
// while the RegExp is on the shape every fresh RegExp gets. A RegExp that has
// left that shape (lastIndex made read-only, an extra own property) must go
// back to the checked path.

var pass = 0, fail = 0;
function ok(c, m) { if (c) { pass++; } else { fail++; print('FAIL: ' + m); } }

for (var i = 0; i < 200; i++) {
    var g = /a/g;
    g.exec('xa');
    ok(g.lastIndex === 2, 'global exec advances lastIndex');
    g.exec('xa');
    ok(g.lastIndex === 0, 'failed global exec resets lastIndex');
}

var frozen = /a/g;
Object.defineProperty(frozen, 'lastIndex', { writable: false });
var threw = false;
try { frozen.exec('a'); } catch (e) { threw = e instanceof TypeError; }
ok(threw, 'exec on a read-only lastIndex throws TypeError');
ok(frozen.lastIndex === 0, 'read-only lastIndex unchanged');

var sticky = /b/y;
sticky.lastIndex = 1;
ok(sticky.test('ab') && sticky.lastIndex === 2, 'sticky reads the written lastIndex');

var extra = /c/g;
extra.foo = 1;
extra.lastIndex = 1;
ok(extra.exec('cc').index === 1 && extra.lastIndex === 2, 'RegExp with an extra property');

var big = /d/g;
big.lastIndex = 5;
ok(big.exec('dd') === null && big.lastIndex === 0, 'lastIndex past the end resets');

print(fail === 0 ? 'PASS ' + pass : 'FAIL ' + fail);
