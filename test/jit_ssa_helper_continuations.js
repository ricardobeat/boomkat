// A helper must keep the generated caller active, preserve unboxed values,
// publish roots before callbacks, and never replay a completed call or store.
function checkContinuation(ok, message) {
    if (!ok) throw new Error(message);
}
function helperLoop(o, n, callback) {
    var total = 0.25;
    for (var i = 0; i < n; i++) {
        o.before = o.before + 1;
        var returned = callback(i, o);
        total = total + returned;
        o.after = o.after + 1;
    }
    return total;
}
function makeHelperCallback(step) {
    return function(i, o) {
        o.called = o.called + 1;
        // Root both the receiver and a freshly allocated object/string while
        // the suspended native caller retains its numeric accumulator.
        o.last = {text: 'continuation:' + i, previous: o.last};
        return i + step;
    };
}
var helperCallback = makeHelperCallback(0.5);
for (var warm = 0; warm < 48; warm++) {
    var warmState = {before: 0, after: 0, called: 0, last: null};
    checkContinuation(helperLoop(warmState, 20, helperCallback) === 200.25, 'typed value across callback');
    checkContinuation(warmState.before === 20 && warmState.after === 20 && warmState.called === 20,
        'callback/store exactly once');
    checkContinuation(warmState.last.text === 'continuation:19', 'closure allocation roots');
}
// A post-call numeric guard fails after the callback has already changed state.
var late = {before: 0, after: 0, called: 0, last: null};
var lateResult = helperLoop(late, 4, function(i, o) {
    o.called++;
    return i === 2 ? 'x' : i + 0.5;
});
checkContinuation(lateResult === '2.25x3.5' && late.before === 4 && late.after === 4 && late.called === 4,
    'late guard never replays callback');
var throwing = {before: 0, after: 0, called: 0, last: null};
var caught = false;
try {
    helperLoop(throwing, 10, function(i, o) {
        o.called++;
        if (i === 3) throw 'continuation sentinel';
        return i;
    });
} catch (error) {
    caught = error === 'continuation sentinel';
}
checkContinuation(caught && throwing.before === 4 && throwing.called === 4 && throwing.after === 3,
    'throw exact frame and effects');
// Empty allocations also use the same helper boundary in the SSA caller.
function allocatingLoop(o, n, use) {
    var sum = 0.5;
    for (var i = 0; i < n; i++) {
        o.count = o.count + 1;
        var value = [];
        sum = sum + use(value, i);
    }
    return sum;
}
for (var allocWarm = 0; allocWarm < 40; allocWarm++) {
    var allocationState = {count: 0};
    checkContinuation(allocatingLoop(allocationState, 12, function(value, i) {
        value.push('root:' + i);
        return value.length + i;
    }) === 78.5 && allocationState.count === 12, 'allocation continuation');
}
console.log('JIT SSA helper continuations: PASS');
// Force a callback frame large enough that recursive execution grows the VM
// value stack. The suspended caller must reload its base and preserve roots.
var growthSource = 'return function growingFrame(n){';
var growthSum = '';
for (var local = 0; local < 80; local++) {
    growthSource += 'var v' + local + '=n+' + local + ';';
    growthSum += (local ? '+' : '') + 'v' + local;
}
growthSource += 'var child=n?growingFrame(n-1):0;return child+' + growthSum + ';}';
var growingFrame = Function(growthSource)();
var growthState = {before: 0, after: 0, called: 0, last: null};
var growthResult = helperLoop(growthState, 5, function(i, o) {
    o.called++;
    o.last = {sum: growingFrame(80), previous: o.last};
    return i + 0.5;
});
checkContinuation(growthResult === 12.75 && growthState.before === 5 && growthState.after === 5
    && growthState.called === 5 && growthState.last.sum === 515160, 'movable frame continuation');
console.log('JIT SSA helper stack growth: PASS');
