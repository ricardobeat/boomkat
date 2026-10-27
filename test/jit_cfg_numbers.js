// Force a hot region inside a function larger than the whole-function tier.
// The diamond carries one numeric accumulator through both predecessors.
var cfgSource = 'function jitCfgNumbers(o,n){var seed=0;';
for (var cfgPad = 0; cfgPad < 600; cfgPad++) cfgSource += 'seed += 1;';
cfgSource += 'var sum=seed;for(var i=0;i<n;i++){if(i==n)sum=sum+sum;if(i&1)sum=sum+o.left;else sum=sum+o.right;}return sum;}';
eval(cfgSource);
var cfgValues = { left: 1.25, right: 2.5 };
for (var cfgWarm = 0; cfgWarm < 100; cfgWarm++) {
    if (jitCfgNumbers(cfgValues, 100) !== 787.5) throw new Error('numeric phi');
}
// A side exit must publish every carried value before coercion, without
// redoing prior iterations or truncating a double to an integer.
var cfgCoercions = 0;
cfgValues.left = { valueOf: function () { cfgCoercions++; return 0.75; } };
if (jitCfgNumbers(cfgValues, 100) !== 762.5 || cfgCoercions !== 50) throw new Error('numeric recovery');
cfgValues.left = NaN;
if (!Number.isNaN(jitCfgNumbers(cfgValues, 2))) throw new Error('numeric NaN');
cfgValues.left = 1.25;
if (jitCfgNumbers(cfgValues, 100) !== 787.5) throw new Error('numeric reentry');

// Canonical lanes must survive native callees, object allocation and the
// array-growth helper. Repeated effects expose a wrong continuation PC.
function jitCfgStep(x, counts) {
    counts.calls = counts.calls + 1;
    return x * 2 + 0.5;
}
var cfgStepper = { step: jitCfgStep };
function jitCfgCalls(sum, n, values, counts) {
    for (var i = 0; i < n; i++) {
        if (i == n) sum = sum + sum;
        var pair = {};
        values.push(pair);
        sum = sum + cfgStepper.step(i, counts);
        if (i & 1) sum = sum + 0.25;
        else sum = sum + 0.5;
    }
    return sum;
}
for (var cfgCallWarm = 0; cfgCallWarm < 100; cfgCallWarm++) {
    var cfgCounts = { calls: 0 }, cfgArray = [];
    if (jitCfgCalls(0.75, 100, cfgArray, cfgCounts) !== 9988.25 ||
        cfgCounts.calls !== 100 || cfgArray.length !== 100 || typeof cfgArray[99] !== 'object')
        throw new Error('numeric call continuation');
}
var cfgInitialCoercions = 0;
var cfgInitial = { valueOf: function () { cfgInitialCoercions++; return 0.75; } };
var cfgCounts = { calls: 0 }, cfgArray = [];
if (jitCfgCalls(cfgInitial, 100, cfgArray, cfgCounts) !== 9988.25 ||
    cfgInitialCoercions !== 1 || cfgCounts.calls !== 100 || cfgArray.length !== 100)
    throw new Error('numeric entry recovery');
cfgStepper.run = jitCfgCalls;
function jitCfgDrive(initial, values, counts) {
    var first = cfgStepper.run(initial, 100, values, counts);
    return first + cfgStepper.run(0.75, 100, values, counts);
}
for (var cfgDriveWarm = 0; cfgDriveWarm < 100; cfgDriveWarm++) {
    if (jitCfgDrive(0.75, [], { calls: 0 }) !== 19976.5) throw new Error('numeric native entry');
}
cfgInitialCoercions = 0;
cfgCounts = { calls: 0 }; cfgArray = [];
if (jitCfgDrive(cfgInitial, cfgArray, cfgCounts) !== 19976.5 || cfgInitialCoercions !== 1 ||
    cfgCounts.calls !== 200 || cfgArray.length !== 200) throw new Error('numeric native entry recovery');
function jitCfgShort(initial, values, counts) {
    return cfgStepper.run(initial, 2, values, counts) + 0.25;
}
for (var cfgShortWarm = 0; cfgShortWarm < 100; cfgShortWarm++) {
    if (jitCfgShort(0.75, [], { calls: 0 }) !== 4.75) throw new Error('numeric short native return');
}
console.log('JIT CFG numbers: PASS');
