// Scalar invariants execute in a shared preheader reached by ordinary entry
// and OSR imports. The array write is an observable native-loop consumer.
function invariantEffects(output, count, left, right) {
    var sum = 0.0;
    for (var i = 0; i < count; i++) {
        var invariant = left * 1.25 + right * 0.5;
        output[i] = invariant + i;
        sum = sum + output[i];
    }
    return sum;
}
function invariantCheck(ok, name) { if (!ok) throw new Error(name); }
var output = new Float64Array(4096);
for (var warm = 0; warm < 160; warm++) {
    invariantCheck(invariantEffects(output, 32, 2.0, 3.0) === 624, 'native invariant');
}
// Poll-driven reentry imports the current index and sum, and reruns PH once.
invariantCheck(invariantEffects(output, 4096, 2.0, 3.0) === 8402944, 'OSR invariant');
invariantCheck(output[0] === 4 && output[4095] === 4099, 'stored invariant');
invariantCheck(invariantEffects(output, 0, {}, {}) === 0, 'zero iterations do not coerce');
var conversions = 0;
var boxed = {valueOf: function () { conversions++; return 2; }};
invariantCheck(invariantEffects(output, 3, boxed, 3) === 15, 'boxed replay');
invariantCheck(conversions === 3, 'guarded coercion stays in loop');
var thrown = 0;
try {
    invariantEffects(output, 4, {valueOf: function () { thrown++; throw 'coercion'; }}, 3);
    throw 'missing throw';
} catch (error) { invariantCheck(error === 'coercion', 'throw identity'); }
invariantCheck(thrown === 1, 'throw once');
console.log('SSA external preheader invariants: PASS');
