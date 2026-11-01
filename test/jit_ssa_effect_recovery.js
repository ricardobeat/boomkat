// Run with --jit and --script. Published whole-function SSA must leave every
// completed store committed and resume the first unperformed bytecode.
function assertEffect(value, message) {
    if (!value) throw new Error(message);
}
function effectGuard(o, n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        o.count = o.count + 1;
        total = total + o.value * 2;
    }
    return total;
}
function effectAlias(a, b, n) {
    for (var i = 0; i < n; i++) {
        a.value = a.value + 1;
        b.value = b.value + a.value;
    }
    return a.value;
}
function effectConditional(o, n) {
    for (var i = 0; i < n; i++) {
        if (i & 1) o.odd = o.odd + 1;
        else o.even = o.even + 1;
    }
    return o.odd + o.even;
}
function effectArray(a, o, n) {
    for (var i = 0; i < n; i++) {
        a[i] = a[i] + 1;
        o.count = o.count + 1;
    }
    return o.count;
}
function effectCall(o, n, callback) {
    for (var i = 0; i < n; i++) {
        o.count = o.count + 1;
        var returned = callback(o);
        o.after = o.after + returned * 2;
    }
    return o.count;
}
function effectPhi(o, n, value) {
    var i = 0, sum = 0, carry = 0;
    while (i < n) {
        o.count = o.count + 1;
        sum = sum + carry * 2;
        carry = i < 3 ? 1 : value;
        i++;
    }
    return sum;
}
function makeEffectClosure(step) {
    return {
        run: function capturedEffect(o, n) {
            for (var i = 0; i < n; i++) o.count = o.count + step;
            return o.count;
        },
        set: function(value) { step = value; }
    };
}
var effectClosure = makeEffectClosure(2);
var callbackCount = 0;
function effectCallback(o) { callbackCount++; o.value++; return o.value; }
for (var warm = 0; warm < 96; warm++) {
    assertEffect(effectClosure.run({count: 0}, 5) === 10, 'captured binding');
    var phiState = {count: 0};
    assertEffect(effectPhi(phiState, 8, 2) === 22 && phiState.count === 8, 'warm phi');
    var guard = {count: 0, value: 3};
    assertEffect(effectGuard(guard, 8) === 48 && guard.count === 8, 'warm guard');
    var alias = {value: 1};
    assertEffect(effectAlias(alias, alias, 4) === 46, 'warm alias');
    var conditional = {odd: 0, even: 0};
    assertEffect(effectConditional(conditional, 9) === 9 && conditional.odd === 4 && conditional.even === 5, 'conditional effects');
    var arrayState = {count: 0};
    var array = [1, 2, 3, 4];
    assertEffect(effectArray(array, arrayState, 4) === 4 && array[3] === 5, 'warm array');
    var callState = {count: 0, value: 0, after: 0};
    assertEffect(effectCall(callState, 4, effectCallback) === 4 && callState.value === 4 && callState.after === 20, 'call effects');
}
assertEffect(callbackCount === 384, 'callback executed exactly once');
effectClosure.set(3);
assertEffect(effectClosure.run({count: 0}, 5) === 15, 'changed capture read at entry');
var changedCall = {count: 0, value: 0, after: 0};
var changedCallCount = 0;
assertEffect(effectCall(changedCall, 4, function(o) {
    changedCallCount++;
    o.extra = true;
    o.value = '3';
    return o.value;
}) === 4 && changedCall.after === 24 && changedCallCount === 4, 'call reimport after layout and value change');
var throwingState = {count: 0, value: 0, after: 0};
var caughtEffect = false;
try {
    effectCall(throwingState, 4, function() { throw 'effect sentinel'; });
} catch (error) {
    caughtEffect = error === 'effect sentinel';
}
assertEffect(caughtEffect && throwingState.count === 1, 'throw after exactly one store');
// Backedge conversions must all validate before any carried phi is replaced.
var latePhiState = {count: 0};
assertEffect(effectPhi(latePhiState, 8, '2') === 22 && latePhiState.count === 8, 'late phi conversion');
// The numeric guard fails after count was already stored.
var stringValue = {count: 0, value: '3'};
assertEffect(effectGuard(stringValue, 7) === 42 && stringValue.count === 7, 'late string numeric guard');
// Replacing an old string requires the runtime's reference release path.
var stringCount = {count: 'x', value: 2};
assertEffect(effectGuard(stringCount, 3) === 12 && stringCount.count === 'x111', 'string store ownership');
var stringArrayState = {count: 0};
var mixedArray = [1, '2', 3, 4];
assertEffect(effectArray(mixedArray, stringArrayState, 4) === 4 && mixedArray[0] === 2 && mixedArray[1] === '21', 'late array guard');
// Exhaust the native edge budget after many effects. Replaying from entry
// would increment the counter twice for an already completed prefix.
var budgetState = {count: 0, value: 2};
assertEffect(effectGuard(budgetState, 12000) === 48000 && budgetState.count === 12000, 'budget recovery');
var distinctA = {value: 1}, distinctB = {value: 3};
assertEffect(effectAlias(distinctA, distinctB, 4) === 5 && distinctB.value === 17, 'distinct aliases');
console.log('JIT effect recovery: PASS');
