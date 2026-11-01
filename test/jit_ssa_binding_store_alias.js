// Numeric property stores may target the same backing object as a variable
// binding. Entry binding snapshots are not a proof that these writes disjoint.
var ssaBindingAliasValue = 1;
function globalBindingAlias(o, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        o.ssaBindingAliasValue = o.ssaBindingAliasValue + 1;
        sum = sum + ssaBindingAliasValue;
    }
    return sum;
}
function capturedBindingAlias(o, n) {
    var sum = 0;
    for (var i = 0; i < n; i++) {
        o.count = o.count + 1;
        sum = sum + ssaBindingAliasValue;
    }
    return sum;
}
// Warm the ordinary-shape specialization before exercising the global object
// alias. Dictionary/global layouts can take their exact guard exit.
for (var warmAlias = 0; warmAlias < 80; warmAlias++) {
    ssaBindingAliasValue = 1;
    var warmDistinct = {ssaBindingAliasValue: 3};
    if (globalBindingAlias(warmDistinct, 8) !== 8 || warmDistinct.ssaBindingAliasValue !== 11)
        throw new Error('native binding read');
}
ssaBindingAliasValue = 1;
if (globalBindingAlias(globalThis, 8) !== 44 || ssaBindingAliasValue !== 9)
    throw new Error('global binding aliases property store');
var distinctAlias = {ssaBindingAliasValue: 3};
if (globalBindingAlias(distinctAlias, 4) !== 36 || distinctAlias.ssaBindingAliasValue !== 7)
    throw new Error('distinct binding/property values');
function makeMutableBinding() {
    var value = 1;
    return function capturedCurrentCaller(o, n, change) {
        var sum = 0.25;
        for (var i = 0; i < n; i++) {
            o.count = o.count + 1;
            change(function(x) {value = x;}, i);
            sum = sum + value;
        }
        return sum;
    };
}
var capturedAlias = makeMutableBinding();
for (var warmCaptured = 0; warmCaptured < 40; warmCaptured++) {
    var capturedState = {count: 0};
    var capturedResult = capturedAlias(capturedState, 8, function(set, i) {set(i + 0.5);});
    if (capturedResult !== 32.25 || capturedState.count !== 8)
        throw new Error('mutable binding after callback');
}
console.log('SSA binding/store aliases: PASS');

function ownMutableBinding(o, n, invoke) {
    var value = 0.5;
    var sum = 0.25;
    function setOwnValue(next) {value = next;}
    for (var i = 0; i < n; i++) {
        o.count = o.count + 1;
        invoke(setOwnValue, i);
        sum = sum + value;
    }
    return sum;
}
for (var ownWarm = 0; ownWarm < 80; ownWarm++) {
    var ownState = {count: 0};
    if (ownMutableBinding(ownState, 8, function(set, i) {set(i + 0.5);}) !== 32.25
        || ownState.count !== 8) throw new Error('caller own captured scalar');
}
console.log('SSA own mutable capture: PASS');
