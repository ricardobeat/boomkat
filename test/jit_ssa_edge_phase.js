// A conversion on a post-call CFG edge must never replay the completed call.
var edgePhaseCalls = 0, edgePhaseConversions = 0;
function edgePhaseNumeric(index) {
    edgePhaseCalls++;
    return index + 0.5;
}
function edgePhaseWork(state, callback, count) {
    var total = 0;
    for (var index = 0; index < count; index++) {
        state.before = state.before + 1;
        var value = callback(index);
        total = total + value * 1.25;
        state.after = state.after + 1;
    }
    return total;
}
function edgePhaseCheck(value, message) {
    if (!value) throw new Error(message);
}
for (var warm = 0; warm < 96; warm++) {
    var state = {before: 0, after: 0};
    edgePhaseCheck(edgePhaseWork(state, edgePhaseNumeric, 4) === 10, 'warm sum');
}
function edgePhaseObject(index) {
    edgePhaseCalls++;
    return {valueOf: function () { edgePhaseConversions++; return index + 0.5; }};
}
edgePhaseCalls = 0;
edgePhaseConversions = 0;
var state = {before: 0, after: 0};
edgePhaseCheck(edgePhaseWork(state, edgePhaseObject, 4) === 10, 'object sum');
edgePhaseCheck(edgePhaseCalls === 4 && edgePhaseConversions === 4, 'callback once on edge refusal: ' + edgePhaseCalls + '/' + edgePhaseConversions);
edgePhaseCheck(state.before === 4 && state.after === 4, 'stores once on edge refusal');
function edgePhaseString(index) {
    edgePhaseCalls++;
    return index === 1 ? '1.5' : index + 0.5;
}
edgePhaseCalls = 0;
var state = {before: 0, after: 0};
edgePhaseCheck(edgePhaseWork(state, edgePhaseString, 4) === 10, 'string sum');
edgePhaseCheck(edgePhaseCalls === 4 && state.before === 4 && state.after === 4, 'string callback once');
function edgePhaseThrowing(index) {
    edgePhaseCalls++;
    return {valueOf: function () {
        edgePhaseConversions++;
        if (index === 2) throw 'edge phase';
        return index + 0.5;
    }};
}
edgePhaseCalls = 0;
edgePhaseConversions = 0;
var state = {before: 0, after: 0};
try {
    edgePhaseWork(state, edgePhaseThrowing, 4);
    throw new Error('missing edge throw');
} catch (error) {
    edgePhaseCheck(error === 'edge phase', 'coercion throw identity');
}
edgePhaseCheck(edgePhaseCalls === 3 && edgePhaseConversions === 3, 'throwing callback once');
edgePhaseCheck(state.before === 3 && state.after === 2, 'exact state before coercion throw');
console.log('SSA edge phases: PASS');
