function recoverCheck(actual, expected) {
    if (!Object.is(actual, expected)) throw new Error('inline recovery: ' + actual + ' != ' + expected);
}
function recoverLeaf(n) {
    this.calls++;
    this.sum += n;
    return this.payload + n;
}
function recoverMiddle(n) {
    this.before++;
    var value = this.child.step(n + 1);
    this.after++;
    return value * 2;
}
function recoverDrive(o, count) {
    var total = 0;
    for (var i = 0; i < count; i++) total += o.step(i);
    return total;
}
var recoveryChild = { calls: 0, sum: 0, payload: 10 };
var recoveryOuter = { before: 0, after: 0, child: recoveryChild };
Object.setPrototypeOf(recoveryChild, { step: recoverLeaf });
Object.setPrototypeOf(recoveryOuter, { step: recoverMiddle });
// Populate the nested callees' caches before the driver's first compilation.
for (var warm = 0; warm < 64; warm++) recoveryOuter.step(0);
recoveryChild.calls = recoveryChild.sum = recoveryOuter.before = recoveryOuter.after = 0;
recoverCheck(recoverDrive(recoveryOuter, 300), 96300);
recoverCheck(recoveryChild.sum, 45150);
recoverCheck(recoveryChild.calls, 300);
recoverCheck(recoveryOuter.before, 300);
recoverCheck(recoveryOuter.after, 300);

// The leaf escapes at coercion after both stores. Reconstruct its caller's
// temporaries and continuation; neither the stores nor the nested call repeat.
var recoveryConversions = 0;
recoveryChild.payload = { valueOf: function () { recoveryConversions++; return 7; } };
recoverCheck(recoverDrive(recoveryOuter, 1), 16);
recoverCheck(recoveryConversions, 1);
recoverCheck(recoveryChild.sum, 45151);
recoverCheck(recoveryChild.calls, 301);
recoverCheck(recoveryOuter.before, 301);
recoverCheck(recoveryOuter.after, 301);

var recoveryReads = 0, recoveryFinally = 0;
Object.defineProperty(recoveryChild, 'payload', {
    configurable: true,
    get: function () { recoveryReads++; throw new Error('recovered getter'); }
});
try { recoverDrive(recoveryOuter, 1); throw new Error('missing throw'); }
catch (e) { recoverCheck(e.message, 'recovered getter'); }
finally { recoveryFinally++; }
recoverCheck(recoveryReads, 1);
recoverCheck(recoveryFinally, 1);
recoverCheck(recoveryChild.calls, 302);
recoverCheck(recoveryChild.sum, 45152);
recoverCheck(recoveryOuter.before, 302);
recoverCheck(recoveryOuter.after, 301);

Object.defineProperty(recoveryChild, 'payload', { value: 'word', writable: true });
recoverCheck(recoverDrive(recoveryOuter, 1), NaN);
recoverCheck(recoveryChild.calls, 303);
recoverCheck(recoveryOuter.after, 302);

// Keep live arguments and an earlier result across a nested inline call.
function recoverAdd(a, b) { return this.bias + a * 3 + b; }
function recoverTwice(a, b) { var first = this.add(a, b); return first + this.add(b, a); }
var recoveryArgs = { bias: 7 };
Object.setPrototypeOf(recoveryArgs, { add: recoverAdd, twice: recoverTwice });
for (var i = 0; i < 300; i++) recoverCheck(recoveryArgs.twice(i, i + 9), 8 * i + 50);
function recoveryEquals(a, b) { this.compares++; return a == b; }
function recoveryCompare(a, b) { return this.equal(a, b); }
var recoveryNumbers = { compares: 0 };
Object.setPrototypeOf(recoveryNumbers, { equal: recoveryEquals, compare: recoveryCompare });
for (var i = 0; i < 300; i++) {
    recoverCheck(recoveryNumbers.compare(1.25, 1.5), false);
    recoverCheck(recoveryNumbers.compare(4294967296, 0), false);
    recoverCheck(recoveryNumbers.compare(NaN, NaN), false);
    recoverCheck(recoveryNumbers.compare(-0, 0), true);
}
recoverCheck(recoveryNumbers.compares, 1200);
// A backward-edge poll must reconstruct a partially executed inline loop.
function recoveryLoop(n) {
    for (var i = 0; i < n; i++) this.sum += i;
    return this.sum;
}
function recoveryLoopDrive(o, n) { return o.run(n) + 1; }
var recoveryLoopHolder = { sum: 0 };
Object.setPrototypeOf(recoveryLoopHolder, { run: recoveryLoop });
for (var i = 0; i < 80; i++) recoveryLoopHolder.run(16);
for (var i = 0; i < 80; i++) recoveryLoopDrive(recoveryLoopHolder, 16);
recoveryLoopHolder.sum = 0;
recoverCheck(recoveryLoopDrive(recoveryLoopHolder, 10000), 49995001);
console.log('JIT inline recovery: PASS');
