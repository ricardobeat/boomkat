// Straight-line calls have no backedge safepoint to interrupt threaded
// dispatch. The first invocation warms each property cache; later invocations
// must tail-dispatch instead of retaining one BuiltinContext frame per call.
var builtinStraight = Function('var total=0;' + Array(60001).join('total+=Math.floor(1.75);') + 'return total;');
for (var round = 0; round < 3; round++) {
    if (builtinStraight() !== 60000) throw new Error('straight builtin result');
}

// Generic builtin dispatch must discard its local context before dispatching
// the next opcode. Keep enough calls in one threaded burst to expose C stack
// growth even when JIT compilation removes the surrounding interpreter exits.
function builtinStackBurst(n) {
    var total = 0;
    for (var i = 0; i < n; i++) {
        total += Math.floor(1.75);
        total += Math.ceil(0.25);
        total += Math.abs(-1);
        total += 'abcdef'.indexOf('b');
    }
    return total;
}
for (var warm = 0; warm < 16; warm++) {
    if (builtinStackBurst(50000) !== 200000) throw new Error('builtin burst result');
}

// Completed calls, re-dispatched calls and throws must each happen once.
var builtinStackEffects = 0;
var coercible = { valueOf: function () { builtinStackEffects++; return 3.75; } };
if (Math.floor(coercible) !== 3 || builtinStackEffects !== 1) throw new Error('builtin coercion');
function builtinStackAdd(a) { builtinStackEffects++; return this.base + a; }
if (builtinStackAdd.call({ base: 5 }, 7) !== 12 || builtinStackEffects !== 2) throw new Error('builtin redispatch');
try {
    Math.floor({ valueOf: function () { builtinStackEffects++; throw 42; } });
    throw new Error('builtin throw missing');
} catch (e) {
    if (e !== 42 || builtinStackEffects !== 3) throw new Error('builtin throw replay');
}
print('threaded_builtin_stack: PASS');
