function booleanEqCheck(ok, message) { if (!ok) throw new Error(message); }

function nativeBooleanEquality(value, output, seed) {
    // Keep this consumer in the full decoded body rather than a tiny leaf.
    var n = seed;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0; n=(n+1)|0;
    output.eqFalse = value == false;
    output.eqTrue = value == true;
    output.neFalse = value != false;
    output.neTrue = value != true;
    output.seqFalse = value === false;
    output.seqTrue = value === true;
    output.sneFalse = value !== false;
    output.sneTrue = value !== true;
    output.reverseEq = false == value;
    output.reverseNe = true != value;
    output.reverseSeq = true === value;
    output.reverseSne = false !== value;
    return n;
}

var booleanEqOutput = {eqFalse:false, eqTrue:false, neFalse:false, neTrue:false,
    seqFalse:false, seqTrue:false, sneFalse:false, sneTrue:false,
    reverseEq:false, reverseNe:false, reverseSeq:false, reverseSne:false};
for (var booleanEqWarm = 0; booleanEqWarm < 192; booleanEqWarm++) {
    var booleanEqValue = (booleanEqWarm & 1) === 0;
    booleanEqCheck(nativeBooleanEquality(booleanEqValue, booleanEqOutput, 7) === 57, 'boolean native result');
    booleanEqCheck(booleanEqOutput.eqFalse === !booleanEqValue && booleanEqOutput.eqTrue === booleanEqValue, 'loose booleans');
    booleanEqCheck(booleanEqOutput.neFalse === booleanEqValue && booleanEqOutput.neTrue === !booleanEqValue, 'loose inequality');
    booleanEqCheck(booleanEqOutput.seqFalse === !booleanEqValue && booleanEqOutput.seqTrue === booleanEqValue, 'strict booleans');
    booleanEqCheck(booleanEqOutput.sneFalse === booleanEqValue && booleanEqOutput.sneTrue === !booleanEqValue, 'strict inequality');
    booleanEqCheck(booleanEqOutput.reverseEq === !booleanEqValue && booleanEqOutput.reverseNe === !booleanEqValue, 'reverse loose');
    booleanEqCheck(booleanEqOutput.reverseSeq === booleanEqValue && booleanEqOutput.reverseSne === booleanEqValue, 'reverse strict');
}

function booleanEqualityEffects(value, state, strict) {
    var result = false;
    for (var i = 0; i < 2; i++) {
        state.stores = state.stores + 1;
        result = strict ? value === false : value == false;
        state.equal = result;
    }
    return result;
}
var booleanEffectState = {stores:0, equal:false};
for (var booleanEffectWarm = 0; booleanEffectWarm < 128; booleanEffectWarm++) {
    booleanEqCheck(booleanEqualityEffects(false, booleanEffectState, false) === true, 'warm loose equality');
    booleanEqCheck(booleanEqualityEffects(true, booleanEffectState, true) === false, 'warm strict equality');
}
var booleanEqInputs = [0, 1, null, undefined, '', '0', '1', 0n, 1n, 2n];
function checkBooleanEqualityFallbacks() {
for (var booleanEqIndex = 0; booleanEqIndex < booleanEqInputs.length; booleanEqIndex++) {
    var booleanEqInput = booleanEqInputs[booleanEqIndex];
    booleanEqCheck(nativeBooleanEquality(booleanEqInput, booleanEqOutput, 3) === 53, 'fallback result');
    booleanEqCheck(booleanEqOutput.eqFalse === (booleanEqInput == false) && booleanEqOutput.eqTrue === (booleanEqInput == true), 'fallback loose equality');
    booleanEqCheck(booleanEqOutput.neFalse === (booleanEqInput != false) && booleanEqOutput.neTrue === (booleanEqInput != true), 'fallback loose inequality');
    booleanEqCheck(booleanEqOutput.seqFalse === (booleanEqInput === false) && booleanEqOutput.seqTrue === (booleanEqInput === true), 'fallback strict equality');
    booleanEqCheck(booleanEqOutput.sneFalse === (booleanEqInput !== false) && booleanEqOutput.sneTrue === (booleanEqInput !== true), 'fallback strict inequality');
    booleanEffectState.stores = 0;
    booleanEqCheck(booleanEqualityEffects(booleanEqInput, booleanEffectState, false) === (booleanEqInput == false), 'effect fallback equality');
    booleanEqCheck(booleanEffectState.stores === 2, 'effect fallback replay');
}
var booleanEqConversions = 0;
var booleanEqObject = {valueOf:function(){booleanEqConversions++; return 0;}};
booleanEffectState.stores = 0;
booleanEqCheck(booleanEqualityEffects(booleanEqObject, booleanEffectState, false) === true, 'object coercion result');
booleanEqCheck(booleanEqConversions === 2 && booleanEffectState.stores === 2, 'object coercion exact phase');
booleanEqConversions = 0;
booleanEffectState.stores = 0;
booleanEqCheck(booleanEqualityEffects(booleanEqObject, booleanEffectState, true) === false, 'strict object mismatch');
booleanEqCheck(booleanEqConversions === 0 && booleanEffectState.stores === 2, 'strict equality does not coerce');
var booleanEqThrows = 0;
var booleanEqThrower = {valueOf:function(){booleanEqThrows++; throw 'boolean coercion';}};
booleanEffectState.stores = 0;
try { booleanEqualityEffects(booleanEqThrower, booleanEffectState, false); throw 'missing boolean coercion'; }
catch (error) { booleanEqCheck(error === 'boolean coercion', 'coercion exception'); }
booleanEqCheck(booleanEqThrows === 1 && booleanEffectState.stores === 1, 'throw after committed store');
function deadBooleanEquality(value, state) {
    for (var i = 0; i < 2; i++) {
        state.stores = state.stores + 1;
        value == false;
    }
    return 17;
}
for (var deadBooleanWarm = 0; deadBooleanWarm < 128; deadBooleanWarm++) deadBooleanEquality(false, booleanEffectState);
booleanEqConversions = 0;
booleanEffectState.stores = 0;
booleanEqCheck(deadBooleanEquality(booleanEqObject, booleanEffectState) === 17, 'dead comparison result');
booleanEqCheck(booleanEqConversions === 2 && booleanEffectState.stores === 2, 'dead coercion guards survive');
}
if (typeof booleanEqOnlyNative === 'undefined' || !booleanEqOnlyNative) checkBooleanEqualityFallbacks();
