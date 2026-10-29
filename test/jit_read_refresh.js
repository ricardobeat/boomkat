// A read compiled for an early shape later encounters a stable new shape.
function check(ok, message) { if (!ok) throw new Error(message); }
function readRefresh(o) { return o.x + 1; }
var first = { x: 1 };
var later = { y: 0, x: 2 };
for (var i = 0; i < 200; i++) check(readRefresh(first) === 2, 'first shape');
for (var i = 0; i < 500; i++) check(readRefresh(later) === 3, 'later shape');
later.x = 9;
check(readRefresh(later) === 10, 'updated value');
Object.defineProperty(later, 'x', { get: function () { return 12; }, configurable: true });
check(readRefresh(later) === 13, 'accessor fallback');
print('read refresh ok');
