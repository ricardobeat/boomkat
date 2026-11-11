// A bare-name store to an accessor on the global object runs its setter; without one the store
// is dropped in sloppy code and throws in strict code.
var hit = [];
Object.defineProperty(this, "acc", { get: function () { return 1; }, set: function (v) { hit.push(v); }, configurable: true });
acc = 42;
acc += 1;
acc++;
function f() { acc = 9; for (var i = 0; i < 3; i++) acc = i; }
f();
Object.defineProperty(this, "ro", { get: function () { return 5; }, configurable: true });
ro = 1;
var r = (function () { "use strict"; try { ro = 2; return "no throw"; } catch (e) { return e instanceof TypeError; } })();
console.log(hit.join(), acc, ro, r);
