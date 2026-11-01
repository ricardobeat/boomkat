// Dead numeric results may disappear. Their conversion, memory and replay
// obligations remain, including a throw after an already committed store.
function optimizedDeadResult(state, values, count) {
    for (var index = 0; index < count; index++) {
        state.count = state.count + 1;
        var unused = values[index] * 2.5;
    }
    return state.count;
}
function optimizationCheck(condition, name) {
    if (!condition) throw new Error(name);
}
for (var warm = 0; warm < 96; warm++) {
    var state = {count: 0};
    optimizationCheck(optimizedDeadResult(state, [1.5, 2.5, 3.5, 4.5], 4) === 4,
        'numeric completion');
}
var conversions = 0;
var coerced = {valueOf: function () { conversions++; return 3.5; }};
var state = {count: 0};
optimizationCheck(optimizedDeadResult(state, [1.5, coerced, 3.5, coerced], 4) === 4,
    'coercion completion');
optimizationCheck(conversions === 2 && state.count === 4, 'dead coercion retained');
var state = {count: 0};
optimizationCheck(optimizedDeadResult(state, [1.5, '2.5', 3.5, 4.5], 4) === 4,
    'string conversion after effect');
var state = {count: 0}, throws = 0;
var throwing = {valueOf: function () { throws++; throw 'numeric conversion'; }};
try {
    optimizedDeadResult(state, [1.5, 2.5, throwing, 4.5], 4);
    throw new Error('missing conversion throw');
} catch (error) {
    optimizationCheck(error === 'numeric conversion', 'throw identity');
}
optimizationCheck(throws === 1 && state.count === 3, 'exact state before throw');
console.log('SSA optimization semantics: PASS');
