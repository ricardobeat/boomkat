// Nine arguments deliberately exceed the inliner budget, retaining a native
// call site even when the optimizer learns to expand small loops.
function jitLinkTarget(n, a, b, c, d, e, f, g, h) { for (var j = 0; j < 3; j++) n++; return n; }
function jitLinkDrive(o, n) {
    var total = 0;
    for (var i = 0; i < n; i++) total += o.run(i, 0, 0, 0, 0, 0, 0, 0, 0);
    return total;
}
var jitLinkPrototype = { run: jitLinkTarget };
var jitLinkObject = Object.create(jitLinkPrototype);
for (var i = 0; i < 64; i++) jitLinkObject.run(i, 0, 0, 0, 0, 0, 0, 0, 0);
for (var i = 0; i < 64; i++) {
    if (jitLinkDrive(jitLinkObject, 100) !== 5250) throw new Error('linked call');
}
// The callee identity guard must survive mutation even with a patched target.
jitLinkPrototype.run = function (n) { return n * 2; };
if (jitLinkDrive(jitLinkObject, 100) !== 9900) throw new Error('changed callee');
jitLinkPrototype.run = jitLinkTarget;
if (jitLinkDrive(jitLinkObject, 100) !== 5250) throw new Error('restored callee');
console.log('JIT linked calls: PASS');
