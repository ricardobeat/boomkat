// Native function loops, typed feedback, and pure helper inlining. Also run
// without --jit: observable results and fallback side effects must agree.
function jitRegionCheck(actual, expected, label) {
    if (!Object.is(actual, expected)) throw new Error(label + ': ' + actual + ' != ' + expected);
}
function jitRegionFields(o, n) {
    var sum = 0.25;
    for (var i = 0; i < n; i++) { sum = sum + o.x; sum = sum + o.y; }
    return sum;
}
function jitRegionTyped(a, o, n) {
    var sum = 0.25;
    for (var i = 0; i < n; i++) {
        var k = i & 7;
        a[k] = a[k] + o.step;
        sum = sum + a[k] * o.scale;
    }
    return sum;
}
function jitRegionHelper(a, b) { return a * b + a / b; }
function jitRegionCalls(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) sum = sum + jitRegionHelper(i, 2);
    return sum;
}
var jitRegionRecord = {x: 0.25, y: 1.5};
for (var jitRegionWarm = 0; jitRegionWarm < 100; jitRegionWarm++) {
    jitRegionCheck(jitRegionFields(jitRegionRecord, 32), 56.25, 'warm fields');
    jitRegionCheck(jitRegionCalls(32), 1240, 'warm calls');
    jitRegionCheck(jitRegionTyped(new Int32Array(8), {step: 1, scale: 2}, 16), 48.25, 'warm typed');
}
jitRegionCheck(jitRegionFields(jitRegionRecord, 20000), 35000.25, 'native fields');
jitRegionCheck(jitRegionCalls(20000), 499975000, 'native calls');
var jitRegionKinds = [Int8Array, Uint8Array, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
for (var jitRegionKind = 0; jitRegionKind < jitRegionKinds.length; jitRegionKind++) {
    jitRegionCheck(jitRegionTyped(new jitRegionKinds[jitRegionKind](8), {step: 1, scale: 2}, 64), 576.25, 'typed kind');
}
var jitRegionGets = 0;
jitRegionCheck(jitRegionFields({get x(){jitRegionGets++;return 0.25;}, y:1.5}, 2000), 3500.25, 'getter fallback');
jitRegionCheck(jitRegionGets, 2000, 'getter count');
jitRegionHelper = function(a,b){return a-b;};
jitRegionCheck(jitRegionCalls(1000), 497500, 'rebound helper');
var jitRegionEffects = 0;
jitRegionHelper = function(a,b){jitRegionEffects++;return a*b;};
jitRegionCheck(jitRegionCalls(1000), 999000, 'effectful helper');
jitRegionCheck(jitRegionEffects, 1000, 'effect count');
console.log('SLJIT regions: PASS');
